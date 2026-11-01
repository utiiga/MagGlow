#ifndef MAGGLOW_SMC_H
#define MAGGLOW_SMC_H

#include <stdint.h>

/// Opens the AppleSMC connection. Returns 0 on success.
int smc_open(void);
void smc_close(void);

/// Writes a one-byte value to a four-character SMC key (e.g. "ACLC").
/// Requires root. Returns 0 on success.
int smc_write_u8(const char *key, uint8_t value);

/// Reads a one-byte SMC key into *value. Returns 0 on success.
int smc_read_u8(const char *key, uint8_t *value);

#endif
