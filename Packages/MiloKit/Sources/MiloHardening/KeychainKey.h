#ifndef MILO_HARDENING_KEYCHAIN_KEY_H
#define MILO_HARDENING_KEYCHAIN_KEY_H

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>

CF_IMPLICIT_BRIDGING_ENABLED

/// Returns a retained SecKey reference only when the Keychain result has the expected CF type.
SecKeyRef _Nullable MHCopyKeychainKey(
    CFDictionaryRef _Nonnull query,
    OSStatus *_Nonnull status
) CF_RETURNS_RETAINED;

CF_IMPLICIT_BRIDGING_DISABLED

#endif
