import Foundation
import Security

/// Who signed a bundle. An update is held to one rule: a running app that carries a team identifier is only ever
/// replaced by a copy with a valid signature from that same team. A running app without one (an ad-hoc or
/// unsigned build) has no signer to compare with, so its replacement only has to carry an intact signature.
enum CodeSignature {
    enum Failure: Error, Equatable {
        /// The seal is broken, or the bundle is not signed at all. The status is the Security framework's.
        case invalid(OSStatus)
        case differentSigner
    }

    /// The running app's team identifier; nil for an ad-hoc or unsigned build.
    static func runningTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty
        else { return nil }
        return team
    }

    /// Checks every architecture and the nested code, strictly: what `codesign --verify --deep --strict` checks.
    static func verify(bundle: URL, requiredTeam: String?) throws {
        var target: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(bundle as CFURL, [], &target)
        guard created == errSecSuccess, let target else { throw Failure.invalid(created) }

        var requirement: SecRequirement?
        if let team = requiredTeam {
            // A team identifier is ten letters and digits; anything else is not pasted into a requirement.
            guard !team.isEmpty, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw Failure.differentSigner }
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"" as CFString
            guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess else { throw Failure.differentSigner }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(target, flags, requirement)
        if status == errSecCSReqFailed { throw Failure.differentSigner }
        guard status == errSecSuccess else { throw Failure.invalid(status) }
    }
}
