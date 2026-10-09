import Foundation
import Security

enum AppUpdate {
    enum Failure: LocalizedError {
        case invalidSignature

        var errorDescription: String? {
            "the downloaded app is damaged or does not match this app's signing identity"
        }
    }

    /// An update must satisfy the running app's signing identity as well as
    /// validate every sealed resource, nested executable, and architecture.
    static func verifySignature(at candidate: URL, matching current: URL) throws {
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures)
        var currentCode: SecStaticCode?
        var candidateCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(current as CFURL, [], &currentCode) == errSecSuccess,
              let currentCode,
              SecStaticCodeCheckValidity(currentCode, flags, nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(currentCode, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
              let candidateCode,
              SecStaticCodeCheckValidity(candidateCode, flags, requirement) == errSecSuccess else {
            throw Failure.invalidSignature
        }
    }
}
