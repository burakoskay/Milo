#ifndef MILO_HARDENING_FINGERPRINT_H
#define MILO_HARDENING_FINGERPRINT_H

#include <stddef.h>

int mh_compute_device_id(const char *user_id, char *output_hex, size_t output_hex_len);

#endif
