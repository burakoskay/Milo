#include "KeychainKey.h"

SecKeyRef _Nullable MHCopyKeychainKey(
    CFDictionaryRef _Nonnull query,
    OSStatus *_Nonnull status
) {
    if (status == NULL) {
        return NULL;
    }

    *status = errSecParam;
    if (query == NULL) {
        return NULL;
    }

    CFTypeRef result = NULL;
    *status = SecItemCopyMatching(query, &result);
    if (*status != errSecSuccess) {
        return NULL;
    }
    if (result == NULL || CFGetTypeID(result) != SecKeyGetTypeID()) {
        if (result != NULL) {
            CFRelease(result);
        }
        *status = errSecInvalidItemRef;
        return NULL;
    }

    return (SecKeyRef)result;
}
