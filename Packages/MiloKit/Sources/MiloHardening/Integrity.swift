@_silgen_name("mh_integrity_check_launch") private func cIntegrityCheckLaunch() -> Int32
@_silgen_name("mh_integrity_check_envelope_load") private func cIntegrityCheckEnvelopeLoad() -> Int32
@_silgen_name("mh_integrity_check_scan_loop") private func cIntegrityCheckScanLoop() -> Int32
@_silgen_name("mh_integrity_check_settings_open") private func cIntegrityCheckSettingsOpen() -> Int32
@_silgen_name("mh_integrity_check_signature_sync") private func cIntegrityCheckSignatureSync() -> Int32
@_silgen_name("mh_integrity_check_update_check") private func cIntegrityCheckUpdateCheck() -> Int32
@_silgen_name("mh_integrity_check_paywall") private func cIntegrityCheckPaywall() -> Int32
@_silgen_name("mh_integrity_check_helper_connection") private func cIntegrityCheckHelperConnection() -> Int32

/// Runtime locations that trigger independent integrity checks.
public enum MiloIntegritySite: Sendable {
    case launch
    case envelopeLoad
    case scanLoop
    case settingsOpen
    case signatureSync
    case updateCheck
    case paywall
    case helperConnection
}

/// Thin Swift wrapper around the C integrity-check entry points.
public enum MiloIntegrity {
    /// Runs the integrity check for one call site and returns whether it passed.
    public static func check(_ site: MiloIntegritySite) -> Bool {
        switch site {
        case .launch:
            return cIntegrityCheckLaunch() == 1
        case .envelopeLoad:
            return cIntegrityCheckEnvelopeLoad() == 1
        case .scanLoop:
            return cIntegrityCheckScanLoop() == 1
        case .settingsOpen:
            return cIntegrityCheckSettingsOpen() == 1
        case .signatureSync:
            return cIntegrityCheckSignatureSync() == 1
        case .updateCheck:
            return cIntegrityCheckUpdateCheck() == 1
        case .paywall:
            return cIntegrityCheckPaywall() == 1
        case .helperConnection:
            return cIntegrityCheckHelperConnection() == 1
        }
    }
}
