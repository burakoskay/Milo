#include "Fingerprint.h"
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

int mh_compute_device_id(const char *user_id, char *output_hex, size_t output_hex_len) {
    if (user_id == 0 || output_hex == 0 || output_hex_len < 65) {
        return 0;
    }

    io_service_t platform_expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (platform_expert == 0) {
        return 0;
    }

    CFTypeRef serial_ref = IORegistryEntryCreateCFProperty(platform_expert, CFSTR("IOPlatformSerialNumber"), kCFAllocatorDefault, 0);
    IOObjectRelease(platform_expert);
    if (serial_ref == 0 || CFGetTypeID(serial_ref) != CFStringGetTypeID()) {
        if (serial_ref != 0) {
            CFRelease(serial_ref);
        }
        return 0;
    }

    char serial[256];
    Boolean serial_ok = CFStringGetCString((CFStringRef)serial_ref, serial, sizeof(serial), kCFStringEncodingUTF8);
    CFRelease(serial_ref);
    if (!serial_ok) {
        return 0;
    }

    size_t serial_len = strnlen(serial, sizeof(serial));
    size_t user_len = strnlen(user_id, 128);
    if (serial_len == sizeof(serial) || user_len == 128) {
        return 0;
    }

    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    CC_SHA256_Update(&context, serial, (CC_LONG)serial_len);
    const uint8_t separator = 0;
    CC_SHA256_Update(&context, &separator, 1);
    CC_SHA256_Update(&context, user_id, (CC_LONG)user_len);

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);

    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        int written = snprintf(output_hex + (i * 2), output_hex_len - (i * 2), "%02x", digest[i]);
        if (written != 2) {
            return 0;
        }
    }
    output_hex[64] = '\0';
    return 1;
}
