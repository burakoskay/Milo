#!/usr/bin/swift
import Foundation
import CryptoKit

// ─────────────────────────────────────────────────────────────────────────────
// Milo — Paddle Webhook Diagnostic Tool
// This tool crafts a cryptographically valid Paddle Webhook payload, signs it
// with your Webhook Secret, and fires it at your Supabase Edge Function.
//
// Usage: swift tools/test_paddle_webhook.swift
// ─────────────────────────────────────────────────────────────────────────────

print("╔═════════════════════════════════════════════════════════╗")
print("║  Milo — Paddle Webhook Edge Function Diagnostic Test    ║")
print("╚═════════════════════════════════════════════════════════╝")

// 1. Collect inputs
print("\nEnter your Supabase Project URL (e.g. https://xyz.supabase.co):")
guard let supabaseUrl = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !supabaseUrl.isEmpty else {
    print("❌ Invalid URL.")
    exit(1)
}

print("\nEnter your Paddle Webhook Secret (pdl_...):")
guard let webhookSecret = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !webhookSecret.isEmpty else {
    print("❌ Invalid secret.")
    exit(1)
}

print("\nEnter a Supabase User UUID to test the upgrade on (e.g. from your auth.users table):")
print("(If you don't have one, just press Enter and we will use a dummy UUID to test the crypto signature)")
var targetUserId = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
if targetUserId.isEmpty {
    targetUserId = UUID().uuidString
    print("⚠️ Using dummy UUID: \(targetUserId)")
}

// 2. Craft the dummy Paddle Payload
let payloadString = """
{
  "event_id": "evt_test_12345",
  "event_type": "subscription.created",
  "occurred_at": "2026-05-01T12:00:00.000Z",
  "notification_id": "ntf_test_67890",
  "data": {
    "id": "sub_test_abc",
    "status": "active",
    "customer_id": "ctm_test_xyz",
    "next_billed_at": "2027-05-01T12:00:00.000Z",
    "custom_data": {
      "user_id": "\(targetUserId)"
    }
  }
}
"""

// 3. Sign the payload using HMAC-SHA256 (Paddle Spec)
let ts = String(Int(Date().timeIntervalSince1970))
let signedPayload = "\(ts):\(payloadString)"

let secretKey = SymmetricKey(data: Data(webhookSecret.utf8))
let signature = HMAC<SHA256>.authenticationCode(for: Data(signedPayload.utf8), using: secretKey)
let signatureHex = signature.map { String(format: "%02x", $0) }.joined()

let paddleSignatureHeader = "ts=\(ts);h1=\(signatureHex)"

// 4. Send the POST Request
let endpoint = "\(supabaseUrl)/functions/v1/paddle-webhook"
guard let url = URL(string: endpoint) else {
    print("❌ Invalid Edge Function URL format: \(endpoint)")
    exit(1)
}

var request = URLRequest(url: url)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue(paddleSignatureHeader, forHTTPHeaderField: "Paddle-Signature")
request.httpBody = Data(payloadString.utf8)

print("\n🚀 Firing Webhook at: \(endpoint)")
print("🔐 Signature Header: \(paddleSignatureHeader)\n")

let semaphore = DispatchSemaphore(value: 0)

let task = URLSession.shared.dataTask(with: request) { data, response, error in
    defer { semaphore.signal() }

    if let error = error {
        print("❌ Network Error: \(error.localizedDescription)")
        return
    }

    guard let httpResponse = response as? HTTPURLResponse else {
        print("❌ Invalid Response")
        return
    }

    let body = data.map { String(data: $0, encoding: .utf8) ?? "" } ?? ""

    print("📡 HTTP Status: \(httpResponse.statusCode)")
    print("📦 Response Body: \(body)")

    if httpResponse.statusCode == 200 {
        print("\n✅ SUCCESS! The Edge Function cryptographically verified the payload.")
        if body.contains("Missing custom_data.user_id") {
             print("⚠️ The request was verified, but skipped database insertion due to invalid UUID.")
        } else {
             print("✅ The database profile update command was executed for user: \(targetUserId)")
        }
    } else if httpResponse.statusCode == 401 {
        print("\n❌ FAILED: Unauthorized (401). Your Webhook Secret is incorrect or the Edge Function rejected the signature.")
    } else if httpResponse.statusCode == 404 {
         print("\n❌ FAILED: Not Found (404). You have not deployed the Edge Function to Supabase yet!")
    } else {
        print("\n❌ FAILED: Unexpected status code.")
    }
}

task.resume()
semaphore.wait()
