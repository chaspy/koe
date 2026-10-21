import Foundation

// Dependencies are injected so resolution never needs a real shell or filesystem in tests.
enum ImproveCommand {
    struct Match: Equatable { let path: String; let location: String }
    static func directories(home: String) -> [(String, String)] {
        [(home + "/.local/bin", "local"), ("/opt/homebrew/bin", "homebrew"),
         ("/usr/local/bin", "usr_local"), (home + "/.claude/local", "claude"),
         (home + "/.npm-global/bin", "npm")]
    }
    static func resolve(_ program: String, home: String, executable: (String) -> Bool,
                        lookup: (String) -> String?) -> Match? {
        guard !program.isEmpty else { return nil }
        if program.hasPrefix("/") {
            return executable(program) ? Match(path: program, location: "absolute") : nil
        }
        for (dir, label) in directories(home: home) {
            let path = dir + "/" + program
            if executable(path) { return Match(path: path, location: label) }
        }
        guard let path = lookup(program)?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), executable(path) else { return nil }
        return Match(path: path, location: "login_path")
    }
    static func path(home: String, inherited: String) -> String {
        (directories(home: home).map { $0.0 } + [inherited, "/usr/bin:/bin:/usr/sbin:/sbin"])
            .joined(separator: ":")
    }
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // Preserve arguments and leading environment assignments verbatim; replace only the program token.
    static func token(_ command: String) -> (program: String, range: Range<String.Index>)? {
        var i = command.startIndex
        while i < command.endIndex {
            while i < command.endIndex && command[i].isWhitespace { i = command.index(after: i) }
            let start = i
            var word = "", quote: Character?, escaped = false
            while i < command.endIndex {
                let c = command[i]
                if escaped { word.append(c); escaped = false }
                else if c == "\\" && quote != "'" { escaped = true }
                else if let q = quote { if c == q { quote = nil } else { word.append(c) } }
                else if c == "'" || c == "\"" { quote = c }
                else if c.isWhitespace { break }
                else { word.append(c) }
                i = command.index(after: i)
            }
            guard quote == nil, !escaped else { return nil }
            let assignment = word.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil
            if !assignment && !word.isEmpty { return (word, start..<i) }
        }
        return nil
    }
    static func lookup(_ program: String) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v -- \"$1\"", "koe", program]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
    static func find(_ program: String) -> Match? {
        resolve(program, home: NSHomeDirectory(),
                executable: { FileManager.default.isExecutableFile(atPath: $0) }, lookup: lookup)
    }
}

struct ImproveFailures {
    var consecutive = 0
    var lastNotice: Date?
    var exitCode = 0
    mutating func record(_ code: Int) {
        exitCode = code
        consecutive = code == 0 ? 0 : consecutive + 1
    }
    mutating func takeNotice(now: Date) -> Bool {
        guard consecutive >= 3,
              lastNotice.map({ now.timeIntervalSince($0) >= 86400 }) ?? true else { return false }
        lastNotice = now
        return true
    }
}
