#include "Integrity.h"
#include "ConstantTime.h"
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <mach-o/dyld.h>
#include <stdio.h>

const unsigned char mh_expected_executable_sha256[32] __attribute__((weak)) = {0};
const unsigned long mh_expected_executable_sha256_len __attribute__((weak)) = 0;

static int mh_hash_executable(unsigned char output[CC_SHA256_DIGEST_LENGTH]) {
    char path[4096];
    uint32_t path_size = sizeof(path);
    if (_NSGetExecutablePath(path, &path_size) != 0) {
        return 0;
    }

    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return 0;
    }

    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);

    unsigned char buffer[8192];
    size_t read_count = 0;
    while ((read_count = fread(buffer, 1, sizeof(buffer), file)) > 0) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)read_count);
    }
    int ok = ferror(file) == 0;
    fclose(file);
    if (!ok) {
        return 0;
    }

    CC_SHA256_Final(output, &context);
    return 1;
}

static int mh_integrity_check_executable_hash(void) {
#if defined(DEBUG) || defined(AD_HOC)
    return 1;
#else
    if (&mh_expected_executable_sha256 == 0 || &mh_expected_executable_sha256_len == 0 || mh_expected_executable_sha256_len != CC_SHA256_DIGEST_LENGTH) {
        return 0;
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (!mh_hash_executable(digest)) {
        return 0;
    }
    return mh_ct_equals(digest, mh_expected_executable_sha256, CC_SHA256_DIGEST_LENGTH);
#endif
}

static int mh_integrity_check_requirement(void) {
#if defined(DEBUG) || defined(AD_HOC)
    return 1;
#else
    SecCodeRef code = NULL;
    OSStatus copy_status = SecCodeCopySelf(kSecCSDefaultFlags, &code);
    if (copy_status != errSecSuccess || code == NULL) {
        return 0;
    }

    SecRequirementRef requirement = NULL;
    CFStringRef requirement_source = CFSTR("anchor apple generic and certificate leaf[subject.OU] = \"8N738727QB\" and identifier \"com.monomacaw.milo\"");
    OSStatus requirement_status = SecRequirementCreateWithString(requirement_source, kSecCSDefaultFlags, &requirement);
    if (requirement_status != errSecSuccess || requirement == NULL) {
        CFRelease(code);
        return 0;
    }

    OSStatus validity_status = SecCodeCheckValidity(code, kSecCSCheckAllArchitectures, requirement);
    CFRelease(requirement);
    CFRelease(code);
    return validity_status == errSecSuccess ? 1 : 0;
#endif
}

static int mh_integrity_check_all(void) {
    return mh_integrity_check_requirement() && mh_integrity_check_executable_hash();
}

int mh_integrity_check_launch(void) { return mh_integrity_check_all(); }
int mh_integrity_check_envelope_load(void) { return mh_integrity_check_all(); }
int mh_integrity_check_scan_loop(void) { return mh_integrity_check_all(); }
int mh_integrity_check_settings_open(void) { return mh_integrity_check_all(); }
int mh_integrity_check_signature_sync(void) { return mh_integrity_check_all(); }
int mh_integrity_check_update_check(void) { return mh_integrity_check_all(); }
int mh_integrity_check_paywall(void) { return mh_integrity_check_all(); }
int mh_integrity_check_helper_connection(void) { return mh_integrity_check_all(); }
