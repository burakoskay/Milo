#ifndef MILO_HARDENING_LICENSE_VERIFY_H
#define MILO_HARDENING_LICENSE_VERIFY_H

#include <stddef.h>
#include <stdint.h>

int mh_license_verify_envelope_with_public_key(
    const uint8_t *envelope,
    size_t envelope_len,
    const uint8_t *signature,
    size_t signature_len,
    const uint8_t *public_key,
    size_t public_key_len
);

#endif
