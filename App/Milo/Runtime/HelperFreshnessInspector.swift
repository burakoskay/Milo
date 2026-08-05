import Foundation
import MiloDomain
import Security

/// Measures whether the privileged helper answering Milo is running the code Milo installed.
///
/// `MiloHelperFreshnessPolicy` decides the verdict; everything that has to ask the Security
/// framework lives here, mirroring the `MiloProcessSafetyPolicy` / `ProcessSafetyInspector`
/// split.
///
/// **This is a correctness signal, not a security control.** A stale helper is genuinely signed
/// Milo helper code and satisfies the XPC connection's code-signing requirement exactly as a
/// current one does. That requirement, set in `MiloPrivilegedHelperClient`, remains the security
/// boundary. The question here is *which build* is answering.
///
/// It has to be asked because installing over a running Milo leaves the previous helper process
/// alive and serving requests while `launchctl` still reports the registration as running. The
/// helper enforces its own refusal of session-critical executables, so a helper from an earlier
/// build enforces the policy it was compiled with rather than the one the user installed.
///
/// The comparison is code identity, not a version string the helper could report wrongly and not
/// a timestamp that a copy can preserve.
///
/// SAFETY: this type holds no state. Every value is derived per call from the bundle and the
/// supplied pid, so there is nothing to serialize.
enum HelperFreshnessInspector {
    /// The helper binary inside the app bundle, as named by `BundleProgram` in
    /// `com.gonggong.milo.helper.plist`. Both must move together.
    static let installedHelperRelativePath = "Contents/Resources/MiloPrivilegedHelper"

    /// Compares the running helper against the helper binary installed in this bundle.
    ///
    /// - Parameter processIdentifier: the pid of the peer answering the live XPC connection.
    ///   It must come from an established connection: a pid read before the peer exists
    ///   identifies nothing, and a pid is not an identity on its own.
    static func freshness(ofHelperWithProcessIdentifier processIdentifier: pid_t) -> MiloHelperFreshness {
        guard processIdentifier > 0 else {
            return report(.undetermined(.peerProcessUnknown))
        }

        let uniqueIdentity: Data
        switch installedHelperCodeIdentity() {
        case .success(let identity):
            uniqueIdentity = identity
        case .failure(let reason):
            return report(.undetermined(reason))
        }

        let requirement: SecRequirement
        switch identityRequirement(matching: uniqueIdentity) {
        case .success(let compiled):
            requirement = compiled
        case .failure(let status):
            return report(.undetermined(.identityRequirementUnavailable(status: status)))
        }

        let attributes = [kSecGuestAttributePid: NSNumber(value: processIdentifier)] as CFDictionary
        var code: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard copyStatus == errSecSuccess, let code else {
            return report(.undetermined(.codeIdentityUnavailable(status: copyStatus)))
        }

        // A stale helper is caught here in one of two ways. macOS reports
        // `errSecCSStaticCodeChanged` when the on-disk binary no longer matches the running
        // image — the ordinary reinstall — and `errSecCSReqFailed` when the running code simply
        // is not the installed binary. The policy maps both, and refuses to guess at anything else.
        let validationStatus = SecCodeCheckValidity(code, [], requirement)
        return report(MiloHelperFreshnessPolicy.freshness(forCodeValidationStatus: validationStatus))
    }

    // MARK: - Installed helper identity

    private enum InstalledIdentity {
        case success(Data)
        case failure(MiloHelperFreshnessUnknownReason)
    }

    /// The unique code identity (CDHash) of the helper binary shipped inside this bundle.
    private static func installedHelperCodeIdentity() -> InstalledIdentity {
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent(installedHelperRelativePath)
            .standardizedFileURL

        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(helperURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let staticCode else {
            return .failure(.installedHelperUnreadable(status: createStatus))
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(staticCode, [], &information)
        guard informationStatus == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return .failure(.installedHelperUnreadable(status: informationStatus))
        }

        guard let unique = dictionary[kSecCodeInfoUnique as String] as? Data, !unique.isEmpty else {
            return .failure(.installedHelperIdentityMissing)
        }
        return .success(unique)
    }

    private enum CompiledRequirement {
        case success(SecRequirement)
        case failure(Int32)
    }

    /// A `cdhash` requirement naming exactly the installed binary's identity.
    private static func identityRequirement(matching uniqueIdentity: Data) -> CompiledRequirement {
        let hexadecimal = uniqueIdentity.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            "cdhash H\"\(hexadecimal)\"" as CFString,
            [],
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            return .failure(status)
        }
        return .success(requirement)
    }

    // MARK: - Logging

    /// Logs a verdict Milo could not reach, then returns it unchanged.
    ///
    /// A failed measurement is worth a log line and nothing else: it is not shown to the user,
    /// because telling someone their helper might be wrong on the strength of a measurement that
    /// did not happen is worse than staying quiet.
    private static func report(_ freshness: MiloHelperFreshness) -> MiloHelperFreshness {
        switch freshness {
        case .current:
            break
        case .stale(let reason):
            MiloLog.error(
                .privilegedHelperStale,
                category: .privileges,
                detail: reason.rawValue
            )
        case .undetermined(let reason):
            MiloLog.error(
                .privilegedHelperFreshnessUnknown,
                category: .privileges,
                detail: reason.diagnosticDetail
            )
        }
        return freshness
    }
}
