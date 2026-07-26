#include "Integrity.h"
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

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
    CFStringRef requirement_source = CFSTR(
        "anchor apple generic and certificate leaf[subject.OU] = \"8N738727QB\" "
        "and (identifier \"com.monomacaw.milo\" or identifier \"com.monomacaw.milo.preview\")"
    );
    OSStatus requirement_status = SecRequirementCreateWithString(requirement_source, kSecCSDefaultFlags, &requirement);
    if (requirement_status != errSecSuccess || requirement == NULL) {
        CFRelease(code);
        return 0;
    }

    OSStatus validity_status = SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement);
    CFRelease(requirement);
    CFRelease(code);
    return validity_status == errSecSuccess ? 1 : 0;
#endif
}

static int mh_integrity_check_all(void) {
    return mh_integrity_check_requirement();
}

int mh_integrity_check_launch(void) { return mh_integrity_check_all(); }
int mh_integrity_check_envelope_load(void) { return mh_integrity_check_all(); }
int mh_integrity_check_scan_loop(void) { return mh_integrity_check_all(); }
int mh_integrity_check_settings_open(void) { return mh_integrity_check_all(); }
int mh_integrity_check_signature_sync(void) { return mh_integrity_check_all(); }
int mh_integrity_check_update_check(void) { return mh_integrity_check_all(); }
int mh_integrity_check_paywall(void) { return mh_integrity_check_all(); }
int mh_integrity_check_helper_connection(void) { return mh_integrity_check_all(); }
