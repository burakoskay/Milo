#include "ConstantTime.h"

int mh_ct_equals(const uint8_t *a, const uint8_t *b, size_t len) {
    if (len == 0) {
        return 1;
    }
    if (a == 0 || b == 0) {
        return 0;
    }

    uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= (uint8_t)(a[i] ^ b[i]);
    }
    return diff == 0;
}
