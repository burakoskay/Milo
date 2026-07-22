#include "LicenseVerify.h"
#include "ConstantTime.h"
#include "HoneypotChecks.h"
#include <stdint.h>

extern int mh_ed25519_verify_primitive(
    const uint8_t *msg,
    size_t msg_len,
    const uint8_t *sig,
    size_t sig_len,
    const uint8_t *pubkey,
    size_t pubkey_len
);

static int mh_is_json_boundary_valid(const uint8_t *envelope, size_t envelope_len) {
    if (envelope == 0 || envelope_len < 2 || envelope_len > 16384) {
        return 0;
    }
    if (envelope[0] != (uint8_t)'{' || envelope[envelope_len - 1] != (uint8_t)'}') {
        return 0;
    }

    int depth = 0;
    int in_string = 0;
    int escaped = 0;
    for (size_t i = 0; i < envelope_len; i++) {
        uint8_t byte = envelope[i];
        if (byte < 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) {
            return 0;
        }
        if (in_string) {
            if (escaped) {
                escaped = 0;
            } else if (byte == (uint8_t)'\\') {
                escaped = 1;
            } else if (byte == (uint8_t)'"') {
                in_string = 0;
            }
            continue;
        }
        if (byte == (uint8_t)'"') {
            in_string = 1;
        } else if (byte == (uint8_t)'{') {
            depth++;
        } else if (byte == (uint8_t)'}') {
            depth--;
            if (depth < 0) {
                return 0;
            }
        }
    }
    return depth == 0 && in_string == 0 && escaped == 0;
}

static int mh_contains_token(const uint8_t *envelope, size_t envelope_len, const uint8_t *token, size_t token_len) {
    if (envelope == 0 || token == 0 || token_len == 0 || envelope_len < token_len) {
        return 0;
    }
    for (size_t i = 0; i <= envelope_len - token_len; i++) {
        if (mh_ct_equals(envelope + i, token, token_len) == 1) {
            return 1;
        }
    }
    return 0;
}

static int mh_has_hex_device_id(const uint8_t *envelope, size_t envelope_len) {
    const uint8_t key[] = { '"', 'd', 'e', 'v', 'i', 'c', 'e', 'I', 'd', '"', ':' };
    if (envelope == 0 || envelope_len < sizeof(key) + 66) {
        return 0;
    }
    for (size_t i = 0; i <= envelope_len - sizeof(key) - 66; i++) {
        if (mh_ct_equals(envelope + i, key, sizeof(key)) != 1) {
            continue;
        }
        size_t quote_index = i + sizeof(key);
        if (envelope[quote_index] != (uint8_t)'"' || envelope[quote_index + 65] != (uint8_t)'"') {
            return 0;
        }
        for (size_t j = 0; j < 64; j++) {
            uint8_t byte = envelope[quote_index + 1 + j];
            if (!((byte >= (uint8_t)'0' && byte <= (uint8_t)'9') || (byte >= (uint8_t)'a' && byte <= (uint8_t)'f'))) {
                return 0;
            }
        }
        return 1;
    }
    return 0;
}

static int mh_schema_is_supported(const uint8_t *envelope, size_t envelope_len) {
    const uint8_t protocol_version[] = { '"', 'p', 'r', 'o', 't', 'o', 'c', 'o', 'l', 'V', 'e', 'r', 's', 'i', 'o', 'n', '"', ':', '1' };
    const uint8_t app_id[] = { '"', 'a', 'p', 'p', 'I', 'd', '"', ':', '"', 'm', 'i', 'l', 'o', '"' };
    return mh_contains_token(envelope, envelope_len, protocol_version, sizeof(protocol_version))
        && mh_contains_token(envelope, envelope_len, app_id, sizeof(app_id));
}

int mh_license_verify_envelope_with_public_key(
    const uint8_t *envelope,
    size_t envelope_len,
    const uint8_t *signature,
    size_t signature_len,
    const uint8_t *public_key,
    size_t public_key_len
) {
    if (envelope == 0 || signature == 0 || public_key == 0 || envelope_len == 0 || envelope_len > 16384 || signature_len != 64 || public_key_len != 32) {
        return 0;
    }
    if (!mh_is_json_boundary_valid(envelope, envelope_len) || !mh_schema_is_supported(envelope, envelope_len) || !mh_has_hex_device_id(envelope, envelope_len)) {
        return 0;
    }

    if (mh_ed25519_verify_primitive(envelope, envelope_len, signature, signature_len, public_key, public_key_len) != 1) {
        return 0;
    }

    return mh_isPro(envelope, envelope_len, signature, signature_len);
}
