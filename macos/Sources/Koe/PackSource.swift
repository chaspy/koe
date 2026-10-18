import Foundation

// Where shared packs and people lists are fetched from (packSources / peopleSources):
//   gh:owner/repo/path/to/file.txt  … through the gh CLI, run directly with an argument list (no shell)
//   https://…/file.txt              … fetched as is
// Values that do not fit the allowlist below are ignored.
enum PackSource {
    struct GitHub: Equatable {
        let owner: String
        let repo: String
        let path: String
    }

    private static func isSafeSegment(_ s: Substring, maxLength: Int) -> Bool {
        guard !s.isEmpty, s.count <= maxLength, s != ".", s != ".." else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c.isASCII && (CharacterSet.alphanumerics.contains(c))) || c == "." || c == "_" || c == "-"
        }
    }

    // gh:owner/repo/path → parts, or nil when any part has characters outside [A-Za-z0-9._-] (path: also "/")
    static func gitHub(_ src: String) -> GitHub? {
        guard src.hasPrefix("gh:") else { return nil }
        let parts = src.dropFirst(3).split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              isSafeSegment(parts[0], maxLength: 39),
              isSafeSegment(parts[1], maxLength: 100),
              parts[2].count <= 512 else { return nil }
        let segments = parts[2].split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy({ isSafeSegment($0, maxLength: 255) }) else { return nil }
        return GitHub(owner: String(parts[0]), repo: String(parts[1]), path: String(parts[2]))
    }

    static func ghArguments(_ g: GitHub) -> [String] {
        ["api", "repos/\(g.owner)/\(g.repo)/contents/\(g.path)", "-H", "Accept: application/vnd.github.raw"]
    }

    // https URLs only (with a host)
    static func web(_ src: String) -> URL? {
        guard let url = URL(string: src), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    static func isUsable(_ src: String) -> Bool { gitHub(src) != nil || web(src) != nil }

    // File name of the local copy; nil when it would not be a plain file name
    static func cacheName(_ src: String) -> String? {
        let name = (src as NSString).lastPathComponent
        guard isUsable(src), !name.isEmpty, name != ".", name != "..", !name.contains("/") else { return nil }
        return name
    }

    // Shown in the config import dialog: every source, and which of them will be ignored
    static func importNotice(packs: [String], people: [String]) -> String {
        guard !packs.isEmpty || !people.isEmpty else { return "" }
        var s = "\n\n⚠️ 次の取り込み元から、1 日 1 回この Mac に取り込みます（gh: はログイン中の gh で取ります）。配布元を信頼できる場合だけ読み込んでください:"
        for (label, list) in [("用語パック", packs), ("社員名簿", people)] {
            for src in list { s += "\n・\(label): \(src)" + (isUsable(src) ? "" : "（使えない形式のため無視します）") }
        }
        return s
    }

    // Absolute path of gh: the usual install locations first, then the login shell's PATH (a fixed command).
    static func ghCandidates(home: String) -> [String] {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(home)/.local/bin/gh", "/usr/bin/gh"]
    }

    static func resolveGh(home: String = NSHomeDirectory(),
                          isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                          loginShellLookup: () -> String? = PackSource.loginShellGh) -> String? {
        if let found = ghCandidates(home: home).first(where: isExecutable) { return found }
        guard let p = loginShellLookup()?.trimmingCharacters(in: .whitespacesAndNewlines),
              p.hasPrefix("/"), isExecutable(p) else { return nil }
        return p
    }

    static func loginShellGh() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v gh"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.split(whereSeparator: \.isNewline).first.map(String.init)
    }
}
