import Foundation
import Security

// Checks the code signature of a downloaded Koe.app before the in-app updater puts it in place.
// The app must be signed with Koe's Developer ID (team 9RQ8WG6688, docs/notes/signing.md).
enum UpdateVerify {
    static let requirement = #"anchor apple generic and identifier "io.github.chaspy.koe" and certificate leaf[subject.OU] = "9RQ8WG6688""#

    struct Failure: Error, Equatable {
        let reason: String   // for events.jsonl
        let status: OSStatus
        var message: String {
            switch reason {
            case "unsigned": return "署名がありません"
            case "not_koe": return "Koe の開発元の署名ではありません"
            case "invalid": return "署名が壊れているか、中身が書き換えられています"
            default: return "署名を確かめられませんでした (\(status))"
            }
        }
    }

    static func failure(for status: OSStatus) -> Failure? {
        switch status {
        case errSecSuccess: return nil
        case errSecCSUnsigned: return Failure(reason: "unsigned", status: status)
        case errSecCSReqFailed: return Failure(reason: "not_koe", status: status)
        case errSecCSSignatureFailed, errSecCSBadResource, errSecCSResourcesNotSealed, errSecCSResourcesNotFound,
             errSecCSResourcesInvalid, errSecCSBadMainExecutable, errSecCSInfoPlistFailed, errSecCSBadNestedCode:
            return Failure(reason: "invalid", status: status)
        default: return Failure(reason: "error", status: status)
        }
    }

    // nil = the bundle is valid (all architectures, nested code, strict) and satisfies the requirement
    static func check(appAt url: URL, requirement text: String = requirement) -> Failure? {
        var code: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard created == errSecSuccess, let code else { return failure(for: created) ?? Failure(reason: "error", status: created) }
        var req: SecRequirement?
        let parsed = SecRequirementCreateWithString(text as CFString, [], &req)
        guard parsed == errSecSuccess, let req else { return Failure(reason: "error", status: parsed) }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return failure(for: SecStaticCodeCheckValidity(code, flags, req))
    }
}
