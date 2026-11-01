#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <string.h>

// Layout of the struct AppleSMC exchanges through selector 2 (80 bytes).
typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

enum {
    kSMCHandleYPCEvent = 2,
    kSMCReadKey = 5,
    kSMCWriteKey = 6,
    kSMCGetKeyInfo = 9,
};

static io_connect_t conn = 0;

static uint32_t fourcc(const char *key) {
    return ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16) |
           ((uint32_t)key[2] << 8) | (uint32_t)key[3];
}

static int smc_call(SMCParam *in, SMCParam *out) {
    size_t outSize = sizeof(SMCParam);
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent, in,
                                                 sizeof(SMCParam), out, &outSize);
    if (kr != KERN_SUCCESS) return (int)kr;
    return out->result == 0 ? 0 : -(int)out->result;
}

static int smc_key_info(const char *key, SMCKeyInfo *info) {
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.data8 = kSMCGetKeyInfo;
    int rc = smc_call(&in, &out);
    if (rc == 0) *info = out.keyInfo;
    return rc;
}

int smc_open(void) {
    if (conn) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? 0 : (int)kr;
}

void smc_close(void) {
    if (conn) {
        IOServiceClose(conn);
        conn = 0;
    }
}

int smc_read_u8(const char *key, uint8_t *value) {
    SMCKeyInfo info;
    int rc = smc_key_info(key, &info);
    if (rc) return rc;
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCReadKey;
    rc = smc_call(&in, &out);
    if (rc == 0) *value = out.bytes[0];
    return rc;
}

int smc_write_u8(const char *key, uint8_t value) {
    SMCKeyInfo info;
    int rc = smc_key_info(key, &info);
    if (rc) return rc;
    SMCParam in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = fourcc(key);
    in.keyInfo.dataSize = info.dataSize;
    in.data8 = kSMCWriteKey;
    in.bytes[0] = value;
    return smc_call(&in, &out);
}
