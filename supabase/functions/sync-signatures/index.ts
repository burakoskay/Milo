import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

// Edge Function: sync-signatures
// Imports only reviewed, schema-valid manifests from the monomacaw/milo-signatures repository.
// This function must never scrape arbitrary external blocklists into trusted kill rules.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || ""
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
const SIGNATURE_MANIFEST_URL = Deno.env.get("SIGNATURE_MANIFEST_URL") || ""
const SIGNATURE_SYNC_SECRET = Deno.env.get("SIGNATURE_SYNC_SECRET") || ""
const TRUSTED_MANIFEST_PREFIX = "https://raw.githubusercontent.com/monomacaw/milo-signatures/"

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY)

type ManifestSignature = {
  rule_id?: unknown
  vendor?: unknown
  category?: unknown
  display_name?: unknown
  process_name?: unknown
  launchd_label?: unknown
  launchd_domain?: unknown
  bundle_id?: unknown
  executable_path_pattern?: unknown
  team_id?: unknown
  signing_identifier?: unknown
  min_macos?: unknown
  max_macos?: unknown
  termination_strategy?: unknown
  severity?: unknown
  verified?: unknown
  source_url?: unknown
  source_commit?: unknown
}

type Manifest = {
  schema_version?: unknown
  signature_set_version?: unknown
  signatures?: unknown
}

type ValidSignature = {
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
  source_url: string | null
  source_commit: string | null
  revoked_at: string | null
  deprecated_at: string | null
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  })
}

function bearerToken(authorization: string | null): string | null {
  if (!authorization) {
    return null
  }

  const prefix = "Bearer "
  if (!authorization.startsWith(prefix)) {
    return null
  }

  const token = authorization.slice(prefix.length).trim()
  return token.length > 0 ? token : null
}

function fixedTimeEquals(lhs: string, rhs: string): boolean {
  const encoder = new TextEncoder()
  const left = encoder.encode(lhs)
  const right = encoder.encode(rhs)
  const maxLength = Math.max(left.length, right.length)
  let diff = left.length ^ right.length

  for (let index = 0; index < maxLength; index += 1) {
    const leftByte = index < left.length ? left[index] : 0
    const rightByte = index < right.length ? right[index] : 0
    diff |= leftByte ^ rightByte
  }

  return diff === 0
}

function isAuthorized(req: Request): boolean {
  if (!SIGNATURE_SYNC_SECRET) {
    return false
  }

  const suppliedSecret = bearerToken(req.headers.get("authorization"))
    || req.headers.get("x-milo-sync-secret")
    || ""
  return fixedTimeEquals(suppliedSecret, SIGNATURE_SYNC_SECRET)
}

function optionalString(value: unknown): string | null {
  if (value === undefined || value === null) {
    return null
  }

  if (typeof value === "string" && value.trim().length > 0) {
    return value.trim()
  }

  throw new Error("Invalid optional string")
}

function requiredString(value: unknown, pattern: RegExp, field: string): string {
  if (typeof value !== "string") {
    throw new Error(`Invalid ${field}`)
  }

  const trimmed = value.trim()
  if (!pattern.test(trimmed)) {
    throw new Error(`Invalid ${field}`)
  }

  return trimmed
}

function optionalPatternedString(value: unknown, pattern: RegExp, field: string): string | null {
  const stringValue = optionalString(value)
  if (stringValue === null) {
    return null
  }

  if (!pattern.test(stringValue)) {
    throw new Error(`Invalid ${field}`)
  }

  return stringValue
}

function validateSignature(signature: ManifestSignature, signatureSetVersion: string): ValidSignature {
  const teamID = optionalPatternedString(signature.team_id, /^[A-Z0-9]{10}$/, "team_id")
  const signingIdentifier = optionalPatternedString(signature.signing_identifier, /^[A-Za-z0-9][A-Za-z0-9._-]{1,255}$/, "signing_identifier")
  const bundleID = optionalPatternedString(signature.bundle_id, /^[A-Za-z0-9][A-Za-z0-9._-]{1,255}$/, "bundle_id")

  if (!teamID && !signingIdentifier && !bundleID) {
    throw new Error("Signature rule lacks a strong identity field")
  }

  const category = requiredString(signature.category, /^(bloat|intelligence)$/, "category")
  const terminationStrategy = requiredString(signature.termination_strategy, /^(signal|launchctl_bootout|launchctl_disable|none)$/, "termination_strategy")
  const launchdDomain = requiredString(signature.launchd_domain || "gui", /^(gui|system|both)$/, "launchd_domain")
  const severity = typeof signature.severity === "number" && Number.isInteger(signature.severity)
    ? signature.severity
    : 1

  if (severity < 0 || severity > 3) {
    throw new Error("Invalid severity")
  }

  if (signature.verified !== true) {
    throw new Error("Only reviewed signatures may be imported")
  }

  return {
    rule_id: requiredString(signature.rule_id, /^[a-z0-9][a-z0-9._-]{2,127}$/, "rule_id"),
    schema_version: 2,
    signature_set_version: signatureSetVersion,
    vendor: requiredString(signature.vendor, /^[A-Za-z0-9][A-Za-z0-9 ._-]{1,80}$/, "vendor"),
    category,
    display_name: requiredString(signature.display_name, /^.{1,160}$/, "display_name"),
    process_name: requiredString(signature.process_name, /^.{1,160}$/, "process_name"),
    launchd_label: optionalPatternedString(signature.launchd_label, /^[A-Za-z0-9._-]{1,256}$/, "launchd_label"),
    launchd_domain: launchdDomain,
    bundle_id: bundleID,
    executable_path_pattern: optionalPatternedString(signature.executable_path_pattern, /^[A-Za-z0-9 ._/*+\-[\](){}]+$/, "executable_path_pattern"),
    team_id: teamID,
    signing_identifier: signingIdentifier,
    min_macos: optionalPatternedString(signature.min_macos, /^[0-9]{1,2}(\.[0-9]{1,2}){0,2}$/, "min_macos"),
    max_macos: optionalPatternedString(signature.max_macos, /^[0-9]{1,2}(\.[0-9]{1,2}){0,2}$/, "max_macos"),
    termination_strategy: terminationStrategy,
    severity,
    verified: true,
    source_url: optionalString(signature.source_url),
    source_commit: optionalPatternedString(signature.source_commit, /^[0-9a-f]{7,64}$/i, "source_commit"),
    revoked_at: null,
    deprecated_at: null
  }
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 })
  }

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !SIGNATURE_MANIFEST_URL || !SIGNATURE_SYNC_SECRET) {
    return jsonResponse({ error: "Server is not configured" }, 500)
  }

  if (!isAuthorized(req)) {
    return jsonResponse({ error: "Unauthorized" }, 401)
  }

  if (!SIGNATURE_MANIFEST_URL.startsWith(TRUSTED_MANIFEST_PREFIX)) {
    return jsonResponse({ error: "Untrusted manifest URL" }, 500)
  }

  try {
    const response = await fetch(SIGNATURE_MANIFEST_URL)
    if (!response.ok) {
      return jsonResponse({ error: "Manifest fetch failed" }, 502)
    }

    const manifest = await response.json() as Manifest
    if (manifest.schema_version !== 2 || typeof manifest.signature_set_version !== "string") {
      return jsonResponse({ error: "Invalid manifest header" }, 400)
    }

    if (!Array.isArray(manifest.signatures)) {
      return jsonResponse({ error: "Invalid manifest signatures" }, 400)
    }

    const validSignatures = manifest.signatures.map((signature) => {
      return validateSignature(signature as ManifestSignature, manifest.signature_set_version as string)
    })

    if (validSignatures.length === 0) {
      return jsonResponse({ error: "Manifest contains no signatures" }, 400)
    }

    const { error } = await supabase
      .from("telemetry_signatures")
      .upsert(validSignatures, { onConflict: "rule_id" })

    if (error) {
      console.error("Failed to upsert telemetry signatures", error)
      return jsonResponse({ error: "Database update failed" }, 500)
    }

    const currentRuleIDs = new Set(validSignatures.map((signature) => signature.rule_id))
    const { data: activeRows, error: activeRowsError } = await supabase
      .from("telemetry_signatures")
      .select("rule_id")
      .eq("verified", true)
      .is("revoked_at", null)
      .is("deprecated_at", null)

    if (activeRowsError) {
      console.error("Failed to read active telemetry signatures", activeRowsError)
      return jsonResponse({ error: "Database read failed" }, 500)
    }

    const removedRuleIDs = (activeRows || [])
      .map((row) => row.rule_id)
      .filter((ruleID): ruleID is string => typeof ruleID === "string" && !currentRuleIDs.has(ruleID))

    if (removedRuleIDs.length > 0) {
      const { error: deprecateError } = await supabase
        .from("telemetry_signatures")
        .update({
          verified: false,
          deprecated_at: new Date().toISOString()
        })
        .in("rule_id", removedRuleIDs)

      if (deprecateError) {
        console.error("Failed to deprecate removed telemetry signatures", deprecateError)
        return jsonResponse({ error: "Database deprecation failed" }, 500)
      }
    }

    return jsonResponse({ success: true, updated: validSignatures.length, deprecated: removedRuleIDs.length })
  } catch (error) {
    console.error("Signature sync failed", error)
    return jsonResponse({ error: "Signature sync failed" }, 500)
  }
})
