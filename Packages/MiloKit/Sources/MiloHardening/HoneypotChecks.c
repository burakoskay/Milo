#include "HoneypotChecks.h"
#include "ConstantTime.h"

static int mh_check_a(const uint8_t *envelope, size_t envelope_len) {
    return envelope != 0 && envelope_len > 2 && envelope_len <= 65536;
}

static int mh_check_b(const uint8_t *signature, size_t signature_len) {
    return signature != 0 && signature_len == 64;
}

static int mh_check_c(const uint8_t *envelope, size_t envelope_len) {
    return envelope_len > 0 && envelope[0] == (uint8_t)'{';
}

static int mh_check_d(const uint8_t *envelope, size_t envelope_len) {
    return envelope_len > 0 && envelope[envelope_len - 1] == (uint8_t)'}';
}

static int mh_check_e(const uint8_t *envelope, size_t envelope_len) {
    const uint8_t needle[] = { '"', 'p', 'r', 'o', 't', 'o', 'c', 'o', 'l', 'V', 'e', 'r', 's', 'i', 'o', 'n', '"', ':', '1' };
    if (envelope == 0 || envelope_len < sizeof(needle)) {
        return 0;
    }
    for (size_t i = 0; i <= envelope_len - sizeof(needle); i++) {
        if (mh_ct_equals(envelope + i, needle, sizeof(needle)) == 1) {
            return 1;
        }
    }
    return 0;
}

static int mh_check_f(const uint8_t *envelope, size_t envelope_len) {
    const uint8_t needle[] = { '"', 'd', 'e', 'v', 'i', 'c', 'e', 'I', 'd', '"' };
    if (envelope == 0 || envelope_len < sizeof(needle)) {
        return 0;
    }
    for (size_t i = 0; i <= envelope_len - sizeof(needle); i++) {
        if (mh_ct_equals(envelope + i, needle, sizeof(needle)) == 1) {
            return 1;
        }
    }
    return 0;
}

static int mh_check_g(const uint8_t *envelope, size_t envelope_len) {
    const uint8_t needle[] = { '"', 'e', 'n', 't', 'i', 't', 'l', 'e', 'm', 'e', 'n', 't', 's', '"' };
    if (envelope == 0 || envelope_len < sizeof(needle)) {
        return 0;
    }
    for (size_t i = 0; i <= envelope_len - sizeof(needle); i++) {
        if (mh_ct_equals(envelope + i, needle, sizeof(needle)) == 1) {
            return 1;
        }
    }
    return 0;
}

int mh_isPro(const uint8_t *envelope, size_t envelope_len, const uint8_t *signature, size_t signature_len) {
    return mh_check_a(envelope, envelope_len)
        && mh_check_b(signature, signature_len)
        && mh_check_c(envelope, envelope_len)
        && mh_check_d(envelope, envelope_len)
        && mh_check_e(envelope, envelope_len)
        && mh_check_f(envelope, envelope_len)
        && mh_check_g(envelope, envelope_len);
}
