import Foundation

// Limits for packs synced from packSources (shared repositories). Their terms still go into the
// whisper prompt and the receiver notes; these rules only decide what autocorrect may insert.
// windows/core/synced.go has the same rules.
enum SyncedTerms {
    static let maxLength = 40
    static let maxSpaces = 2
    static let shellCharacters = Set("`$;|&<>(){}[]\\\"'*?!~#")

    // A term from a synced pack replaces text only when it is short, has no control characters
    // or shell metacharacters, and at most a couple of spaces
    static func usable(_ term: String) -> Bool {
        guard !term.isEmpty, term.count <= maxLength else { return false }
        if term.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format && $0.value != 0x200D }) {
            return false
        }
        if term.contains(where: { shellCharacters.contains($0) }) { return false }
        return term.filter { $0 == " " }.count <= maxSpaces
    }

    // Whether a pack file is the local copy of a packSources entry (Application Support/Koe/packs/<file name>)
    static func isSynced(packURL: URL, userPacksDir: URL, sources: [String]) -> Bool {
        guard packURL.deletingLastPathComponent().standardizedFileURL.path == userPacksDir.standardizedFileURL.path else { return false }
        let names = Set(sources.map { ($0 as NSString).lastPathComponent })
        return names.contains(packURL.lastPathComponent)
    }
}
