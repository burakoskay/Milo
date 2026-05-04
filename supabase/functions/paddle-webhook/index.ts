import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// Edge Function: paddle-webhook
// Zero Technical Debt implementation of Paddle's signature verification and subscription state management.
// Crucially, this links a Paddle purchase to a specific Supabase User via the `custom_data` object in checkout.

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const PADDLE_WEBHOOK_SECRET = Deno.env.get("PADDLE_WEBHOOK_SECRET") || "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
const MAX_SIGNATURE_AGE_SECONDS = 300;

type PaddleEvent = {
  event_id?: unknown
  event_type?: unknown
  occurred_at?: unknown
  data?: {
    id?: unknown
    status?: unknown
    customer_id?: unknown
    next_billed_at?: unknown
    custom_data?: {
      user_id?: unknown
    }
  }
}

type DatabaseRpcError = {
  message: string
  code?: string
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" }
  });
}

function hexToBytes(hex: string): Uint8Array | null {
  if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length % 2 !== 0) {
    return null;
  }

  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return bytes;
}

function uuidIsValid(value: unknown): value is string {
  return typeof value === "string"
    && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);
}

function nullableTimestamp(value: unknown): string | null {
  if (value === null || value === undefined) {
    return null;
  }

  if (typeof value === "string" && Number.isFinite(Date.parse(value))) {
    return value;
  }

  throw new Error("Invalid nullable timestamp");
}

serve(async (req) => {
  if (req.method !== 'POST') return new Response("Method not allowed", { status: 405 })

  try {
    if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY || !PADDLE_WEBHOOK_SECRET) {
      return jsonResponse({ error: "Server is not configured" }, 500);
    }

    // 1. Read Raw Body and Paddle Signature Header
    const rawBody = await req.text();
    const signatureHeader = req.headers.get('Paddle-Signature');

    if (!signatureHeader) {
      return new Response("Missing signature header", { status: 400 });
    }

    // 2. Cryptographic Verification of the Webhook Payload
    // Format: ts=1671029288;h1=bd78a2e1d...
    const sigParts = signatureHeader.split(';');
    const tsPart = sigParts.find(p => p.startsWith('ts='));
    const h1Part = sigParts.find(p => p.startsWith('h1='));

    if (!tsPart || !h1Part) {
       return new Response("Invalid signature format", { status: 400 });
    }

    const ts = tsPart.slice("ts=".length);
    const h1 = h1Part.slice("h1=".length);
    if (ts.length === 0 || h1.length === 0) {
      return new Response("Invalid signature format", { status: 400 });
    }

    const timestampSeconds = Number.parseInt(ts, 10);
    if (!Number.isFinite(timestampSeconds)) {
      return new Response("Invalid signature timestamp", { status: 400 });
    }

    const ageSeconds = Math.abs(Math.floor(Date.now() / 1000) - timestampSeconds);
    if (ageSeconds > MAX_SIGNATURE_AGE_SECONDS) {
      return new Response("Expired signature", { status: 401 });
    }

    const signedPayload = `${ts}:${rawBody}`;
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey(
        "raw",
        encoder.encode(PADDLE_WEBHOOK_SECRET),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["verify"]
    );

    const signatureBytes = hexToBytes(h1);
    if (!signatureBytes) {
      return new Response("Invalid signature encoding", { status: 400 });
    }
    const signatureForVerification = new Uint8Array(signatureBytes);

    const isValid = await crypto.subtle.verify(
        "HMAC",
        key,
        signatureForVerification,
        encoder.encode(signedPayload)
    );

    if (!isValid) {
      console.error("Paddle signature verification failed.");
      return new Response("Invalid signature", { status: 401 });
    }

    // 3. Process the Verified Event
    const event = JSON.parse(rawBody) as PaddleEvent;
    console.log(`Processing Paddle Event: ${event.event_type}`);

    if (typeof event.event_id !== "string" || typeof event.event_type !== "string") {
      return new Response("Invalid event payload", { status: 400 });
    }

    if (typeof event.occurred_at !== "string" || !Number.isFinite(Date.parse(event.occurred_at))) {
      return new Response("Invalid event timestamp", { status: 400 });
    }

    const { error: idempotencyError } = await supabase
      .from('paddle_webhook_events')
      .insert({
        event_id: event.event_id,
        event_type: event.event_type,
        occurred_at: event.occurred_at
      });

    if (idempotencyError) {
      if (idempotencyError.code === '23505') {
        return jsonResponse({ received: true, duplicate: true });
      }
      console.error("Failed to record webhook idempotency key:", idempotencyError);
      return new Response("Database error", { status: 500 });
    }

    const data = event.data;
    // We strictly require custom_data.user_id to map the payment to a Supabase profile
    const userId = data?.custom_data?.user_id;

    if (!uuidIsValid(userId)) {
      console.error("Event dropped: Missing custom_data.user_id. The Mac app must pass the Supabase UUID to Paddle Checkout.");
      return new Response("Missing custom_data.user_id", { status: 200 }); // Return 200 so Paddle doesn't retry
    }

    // 4. Update the Supabase Profile based on Subscription Event
    let databaseError: DatabaseRpcError | null = null;

    switch (event.event_type) {
      case 'subscription.created':
      case 'subscription.updated':
        if (
          typeof data?.status !== "string"
          || typeof data.customer_id !== "string"
          || typeof data.id !== "string"
        ) {
          return new Response("Invalid subscription payload", { status: 400 });
        }

        let nextBilledAt: string | null;
        try {
          nextBilledAt = nullableTimestamp(data.next_billed_at);
        } catch (_error) {
          return new Response("Invalid subscription timestamp", { status: 400 });
        }

        const { error: errUpdate } = await supabase.rpc('update_user_subscription', {
            p_user_id: userId,
            p_status: data.status,
            p_customer_id: data.customer_id,
            p_subscription_id: data.id,
            p_next_billing: nextBilledAt,
            p_event_occurred_at: event.occurred_at
        });
        databaseError = errUpdate;
        break;

      case 'subscription.canceled':
        if (typeof data?.id !== "string") {
          return new Response("Invalid subscription payload", { status: 400 });
        }

        const { error: errCancel } = await supabase.rpc('cancel_user_subscription', {
            p_user_id: userId,
            p_event_occurred_at: event.occurred_at
        });
        databaseError = errCancel;
        break;

      default:
         return new Response("Event unhandled but acknowledged", { status: 200 });
    }

    if (databaseError) {
      console.error(`Failed to update profile for user ${userId}:`, databaseError);
      return new Response(`Database error: ${databaseError.message} (Code: ${databaseError.code})`, { status: 500 });
    }

    return jsonResponse({ received: true });

  } catch (err) {
    console.error("Webhook processing error:", err);
    return new Response("Internal Server Error", { status: 500 });
  }
})
