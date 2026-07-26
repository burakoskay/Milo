#ifndef MILO_HARDENING_CONSTANT_TIME_H
#define MILO_HARDENING_CONSTANT_TIME_H

#include <stddef.h>
#include <stdint.h>

int mh_ct_equals(const uint8_t *a, const uint8_t *b, size_t len);

#endif
