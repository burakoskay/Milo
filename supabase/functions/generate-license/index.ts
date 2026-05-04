import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import { ed25519 } from 'npm:@noble/curves/ed25519'

// Edge Function: generate-license
// Responsible for enforcing the device quota and signing the payload with the Ed25519 Private Key.

const PRIVATE_KEY_HEX = Deno.env.get("ED25519_PRIVATE_KEY") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

type ProfileRow = {
  subscription_status: string
  trial_end_date: string | null
  next_billing_date: string | null
}

type SignatureRow = {
  rule_id: string
  schema_version: number
  signature_set_version: string
  vendor: string
  category: string
  display_name: string
  process_name: string
  launchd_label: string | null
  launchd_domain: string
  bundle_id: string | null
  executable_path_pattern: string | null
  team_id: string | null
  signing_identifier: string | null
  min_macos: string | null
  max_macos: string | null
  termination_strategy: string
  severity: number
  verified: boolean
  deprecated_at: string | null
  revoked_at: string | null
  updated_at: string | null
}

type RevocationRow = {
  signature_set_version: string
}

const LICENSE_PAYLOAD_TTL_SECONDS = 7 * 24 * 60 * 60

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  })
}

function requireConfiguredEnvironment(): Response | null {
  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !PRIVATE_KEY_HEX) {
    return jsonResponse({ error: "Server is not configured" }, 500)
  }

  if (!/^[0-9a-fA-F]{64}$/.test(PRIVATE_KEY_HEX)) {
    return jsonResponse({ error: "Invalid signing key configuration" }, 500)
  }

  return null
}

function parsePrivateKeyHex(hex: string): Uint8Array {
  const bytes = new Uint8Array(32)
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16)
  }
  return bytes
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ""
  for (const byte of bytes) {
    binary += String.fromCharCode(byte)
  }
  return btoa(binary)
}

function effectiveSubscriptionStatus(profile: ProfileRow | null): string {
  if (!profile) {
    return "expired"
  }

  if (profile.subscription_status === "active") {
    return "active"
  }

  if (profile.subscription_status === "trial") {
    if (!profile.trial_end_date) {
      return "expired"
    }

    const trialEnd = Date.parse(profile.trial_end_date)
    if (Number.isFinite(trialEnd) && trialEnd > Date.now()) {
      return "trial"
    }
  }

  return "expired"
}

function plusSeconds(date: Date, seconds: number): Date {
  return new Date(date.getTime() + seconds * 1000)
}

function signatureSetVersion(signatures: SignatureRow[]): string {
  const versions = signatures.map((signature) => signature.signature_set_version).filter((version) => version.length > 0)
  const uniqueVersions = [...new Set(versions)].sort()

  if (uniqueVersions.length === 0) {
    return "empty-v2"
  }

  if (uniqueVersions.length === 1) {
    const firstVersion = uniqueVersions[0]
    return typeof firstVersion === "string" ? firstVersion : "empty-v2"
  }

  return `mixed-${uniqueVersions.join(".")}`
}

function formatSignature(row: SignatureRow) {
  return {
    ruleID: row.rule_id,
    schemaVersion: row.schema_version,
    signatureSetVersion: row.signature_set_version,
    vendor: row.vendor,
    category: row.category,
    displayName: row.display_name,
    processName: row.process_name,
    launchdLabel: row.launchd_label,
    launchdDomain: row.launchd_domain,
    bundleID: row.bundle_id,
    executablePathPattern: row.executable_path_pattern,
    teamID: row.team_id,
    signingIdentifier: row.signing_identifier,
    minMacOS: row.min_macos,
    maxMacOS: row.max_macos,
    terminationStrategy: row.termination_strategy,
    severity: row.severity
  }
}

serve(async (req) => {
  try {
    if (req.method !== "POST") {
      return new Response("Method not allowed", { status: 405 })
    }

    const configurationError = requireConfiguredEnvironment()
    if (configurationError) return configurationError

    // 1. Verify user session via Authorization header
    const authHeader = req.headers.get('Authorization')
    if (!authHeader || !authHeader.startsWith("Bearer ")) return new Response("Unauthorized", { status: 401 })
    const token = authHeader.slice("Bearer ".length).trim()
    const { data: { user }, error: authError } = await supabase.auth.getUser(token)
    if (authError || !user) return new Response("Unauthorized", { status: 401 })

    // 2. Parse hardware fingerprint
    const { deviceId } = await req.json()
    if (typeof deviceId !== "string" || !/^[0-9a-f]{64}$/.test(deviceId)) {
      return jsonResponse({ error: "Invalid deviceId" }, 400)
    }

    // 3. Enforce Device Quota (Max 2 devices)
    const { error: deviceError } = await supabase.rpc('register_user_device', {
      p_user_id: user.id,
      p_device_hash: deviceId
    })

    if (deviceError) {
      return jsonResponse({ error: "Device quota reached. Deauthorize an old Mac first." }, 403)
    }

    // 4. Check Subscription Status
    const { data: profile, error: profileError } = await supabase
      .from('profiles')
      .select('subscription_status, trial_end_date, next_billing_date')
      .eq('id', user.id)
      .single();

    if (profileError) {
      return jsonResponse({ error: "Profile not found" }, 404)
    }

    const profileRow = profile as ProfileRow | null
    const status = effectiveSubscriptionStatus(profileRow)

    // 5. Fetch Latest Cloud Signatures
    const { data: signatures, error: signatureError } = await supabase
      .from('telemetry_signatures')
      .select(
        'rule_id, schema_version, signature_set_version, vendor, category, display_name, process_name, launchd_label, launchd_domain, bundle_id, executable_path_pattern, team_id, signing_identifier, min_macos, max_macos, termination_strategy, severity, verified, deprecated_at, revoked_at, updated_at'
      )
      .eq('schema_version', 2)
      .eq('verified', true)
      .is('deprecated_at', null)
      .is('revoked_at', null);

    if (signatureError) {
      return jsonResponse({ error: "Signature sync unavailable" }, 503)
    }

    const signatureRows = (signatures as SignatureRow[] | null) || []

    const { data: revocations, error: revocationError } = await supabase
      .from('telemetry_signature_revocations')
      .select('signature_set_version');

    if (revocationError) {
      return jsonResponse({ error: "Signature revocation state unavailable" }, 503)
    }

    const revokedVersions = ((revocations as RevocationRow[] | null) || [])
      .map((revocation) => revocation.signature_set_version)
      .filter((version) => typeof version === "string" && version.length > 0)

    const now = new Date()
    const expiresAt = plusSeconds(now, LICENSE_PAYLOAD_TTL_SECONDS)
    const activeSignatures = status === "active" || status === "trial"
      ? signatureRows.map(formatSignature)
      : []

    // 6. Construct the cryptographic payload
    const payload = {
      schemaVersion: 2,
      deviceId,
      subscriptionStatus: status,
      trialEndDate: profileRow?.trial_end_date || null,
      nextBillingDate: profileRow?.next_billing_date || null,
      issuedAt: now.toISOString(),
      expiresAt: expiresAt.toISOString(),
      signatureSetVersion: signatureSetVersion(signatureRows),
      revokedSignatureSetVersions: revokedVersions,
      cloudSignatures: activeSignatures
    };

    // 7. Sign Payload using pure JS @noble/curves Ed25519
    const payloadBuffer = new TextEncoder().encode(JSON.stringify(payload));
    const privateKeyBuffer = parsePrivateKeyHex(PRIVATE_KEY_HEX);
    const signature = ed25519.sign(payloadBuffer, privateKeyBuffer);

    // 8. Return Base64 payload and signature to the Mac client
    return new Response(
      JSON.stringify({
        payload: bytesToBase64(payloadBuffer),
        signature: bytesToBase64(signature)
      }),
      { headers: { "Content-Type": "application/json" } }
    )

  } catch (err) {
    console.error("generate-license failed", err)
    return jsonResponse({ error: "Internal Server Error" }, 500)
  }
})
