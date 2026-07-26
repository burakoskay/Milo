#ifndef MILO_HARDENING_HONEYPOT_CHECKS_H
#define MILO_HARDENING_HONEYPOT_CHECKS_H

#include <stddef.h>
#include <stdint.h>

int mh_isPro(const uint8_t *envelope, size_t envelope_len, const uint8_t *signature, size_t signature_len);

#endif
