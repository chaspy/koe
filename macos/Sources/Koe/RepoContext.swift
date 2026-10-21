import AppKit
import ApplicationServices

// 開発の文脈を whisper の手がかりに（U-12）: 前面のターミナルで開いているリポジトリ名とブランチ名を、whisper の初期プロンプトの先頭に足す。
// 渡すのは手元の whisper だけ（LLM 整形・改善ループには渡さない）。読めないとき・迷うときは何も足さない。
//
// どのリポジトリかは、新しい許可を求めずに次の順で探す:
// 1. Terminal.app: 前面のウィンドウが今いるフォルダを持っている（アクセシビリティの AXDocument。今の許可で読める）
// 2. それ以外のターミナル（iTerm・Ghostty 等）: 直前にそのアプリへ貼った文が届いた Claude Code のセッション記録の cwd。
//    貼った数秒後に裏で探して覚えておく（続けて話すとき、同じペインに話している前提）
// 画面の中身・ウィンドウの題名は読まない。events・history の記録には出どころの種類（repo_context）だけを書く
// （history の whisper_prompt には、足したリポジトリ名・ブランチの語もプロンプトの一部として残る）
enum RepoContext {
    // プロンプトの中で使ってよい文字数（用語の枠 120 字から、この分だけ用語を減らす）
    static let maxChars = 40
    // 直前に貼った先のセッションを、この時間だけ覚えておく
    static let keepSeconds: TimeInterval = 1800

    // ブランチ名のうち、手がかりにならない語
    static let stopWords: Set<String> = [
        "feat", "feature", "features", "fix", "bugfix", "hotfix", "chore", "docs", "doc", "refactor", "test", "tests", "ci", "build",
        "perf", "style", "wip", "tmp", "main", "master", "develop", "dev", "release", "revert", "head", "update", "add", "remove",
    ]

    struct Found: Equatable { let repo: String; let branch: String?; let source: String }

    // プロンプトに足す文字列。「リポジトリ名、ブランチの語、…」。用語に既にある語は省く。maxChars に収まるところまで
    static func promptPart(_ f: Found?, terms: [String] = []) -> String {
        guard let f, !f.repo.isEmpty else { return "" }
        let have = Set(terms.map { $0.lowercased() })
        var words: [String] = []
        for w in [f.repo] + branchWords(f.branch) where !have.contains(w.lowercased()) && !words.contains(where: { $0.lowercased() == w.lowercased() }) {
            words.append(w)
        }
        var out = ""
        for w in words {
            let next = out.isEmpty ? w : out + "、" + w
            if next.count > maxChars { break }
            out = next
        }
        return out
    }

    static func branchWords(_ branch: String?) -> [String] {
        guard let b = branch, !b.isEmpty else { return [] }
        return b.split(whereSeparator: { "/-_.".contains($0) }).map(String.init).filter { w in
            w.count >= 2 && !stopWords.contains(w.lowercased()) && !w.allSatisfy(\.isNumber)
        }
    }

    // MARK: - git（git コマンドは呼ばず、.git を直接読む）

    // cwd から上にたどって、リポジトリ名とブランチ名。リポジトリ名は origin の URL の最後（無ければフォルダ名）
    static func git(cwd: String) -> (repo: String, branch: String?)? {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd).standardizedFileURL
        while dir.path != "/" && !dir.path.isEmpty {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    // worktree・submodule: 「gitdir: <場所>」
                    guard let s = try? String(contentsOf: dotGit, encoding: .utf8), let p = gitdirLine(s) else { return nil }
                    gitDir = URL(fileURLWithPath: p, relativeTo: dir).standardizedFileURL
                }
                var common = gitDir
                if let c = try? String(contentsOf: gitDir.appendingPathComponent("commondir"), encoding: .utf8) {
                    common = URL(fileURLWithPath: c.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: gitDir.appendingPathComponent("x")).standardizedFileURL
                }
                let head = (try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8)) ?? ""
                let config = (try? String(contentsOf: common.appendingPathComponent("config"), encoding: .utf8)) ?? ""
                let name = originName(config) ?? (common.lastPathComponent == ".git" ? common.deletingLastPathComponent().lastPathComponent : dir.lastPathComponent)
                return (name, headBranch(head))
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func gitdirLine(_ s: String) -> String? {
        let line = s.split(separator: "\n").first { $0.hasPrefix("gitdir:") }
        return line.map { $0.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces) }
    }

    // 「ref: refs/heads/<名前>」。detached HEAD は nil
    static func headBranch(_ head: String) -> String? {
        let s = head.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("ref: refs/heads/") else { return nil }
        let b = String(s.dropFirst("ref: refs/heads/".count))
        return b.isEmpty ? nil : b
    }

    // [remote "origin"] の url の最後の部分（.git は外す）
    static func originName(_ config: String) -> String? {
        var inOrigin = false
        for raw in config.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inOrigin = line == "[remote \"origin\"]"; continue }
            guard inOrigin, line.hasPrefix("url") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var url = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if url.hasSuffix("/") { url.removeLast() }
            if url.hasSuffix(".git") { url.removeLast(4) }
            let name = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: - Claude Code のセッション記録

    // 貼った文が「人の発話」として入っている行の cwd と gitBranch。新しい行を優先する
    static func sessionMatch(lines: [Substring], pasted: String) -> (cwd: String, branch: String?)? {
        let want = normalize(pasted)
        guard want.count >= 4 else { return nil }
        for line in lines.reversed() where line.contains("\"user\"") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  d["type"] as? String == "user", let cwd = d["cwd"] as? String else { continue }
            let content = (d["message"] as? [String: Any])?["content"]
            let text: String
            if let s = content as? String { text = s }
            else if let arr = content as? [[String: Any]] { text = arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined() }
            else { continue }
            if normalize(text).contains(want) {
                let b = (d["gitBranch"] as? String).flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
                return (cwd, b)
            }
        }
        return nil
    }

    static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) })
    }

    // 最近書かれたセッション記録の末尾から探す
    static func findSession(pasted: String, root: URL, within: TimeInterval = 120) -> (cwd: String, branch: String?)? {
        let fm = FileManager.default
        let now = Date()
        var files: [(URL, Date)] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if now.timeIntervalSince(m) <= within { files.append((f, m)) }
            }
        }
        for (f, _) in files.sorted(by: { $0.1 > $1.1 }) {
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
            // 途中から読むので、先頭が UTF-8 の文字の途中なら 1〜3 バイト捨てる
            guard let data = try? h.readToEnd(), let s = (0...3).lazy.compactMap({ String(data: data.dropFirst($0), encoding: .utf8) }).first else { continue }
            if let m = sessionMatch(lines: s.split(separator: "\n"), pasted: pasted) { return m }
        }
        return nil
    }

    // MARK: - 覚えておく・読む

    private static var remembered: (app: String, found: Found, at: Date)?
    private static let queue = DispatchQueue(label: "koe.repo-context", qos: .utility)

    // ターミナルに貼った後に呼ぶ。数秒待ってから（Claude Code が記録を書くのを待つ）、裏で探して覚える
    static func pasted(_ text: String, app: String) {
        guard Settings.repoContext, Settings.enterApps.contains(app), app != "com.apple.Terminal" else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        queue.asyncAfter(deadline: .now() + 4) {
            guard let m = findSession(pasted: text, root: root), let g = git(cwd: m.cwd) else { return }
            // ブランチは今の .git から読む（記録の gitBranch は、セッションの途中で cd したときに古いフォルダのままのことがある）
            let f = Found(repo: g.repo, branch: g.branch, source: "session")
            DispatchQueue.main.async { remembered = (app, f, Date()) }
        }
    }

    // Terminal.app で録音を始めたときに読んだ結果（押した時刻と合わせて覚える）
    private static var pressed: (app: String, at: Date, found: Found?)?

    // 録音を始めたときに呼ぶ（メインスレッド）。Terminal.app なら、前面のウィンドウのフォルダを裏で先に読んでおく。
    // アクセシビリティの問い合わせは相手のアプリが応答しないと止まるので、メインスレッドでは呼ばない（timeout も短くする）
    static func recordingStarted(app: String, pid: pid_t?) {
        guard Settings.repoContext, app == "com.apple.Terminal", let pid else { return }
        let at = Date()
        pressed = (app, at, nil)
        queue.async {
            let f = terminalFolder(pid: pid).flatMap { git(cwd: $0) }.map { Found(repo: $0.repo, branch: $0.branch, source: "terminal_window") }
            DispatchQueue.main.async { if pressed?.at == at { pressed = (app, at, f) } }
        }
    }

    // 文字起こしの直前に呼ぶ（メインスレッド）。app は録音を始めたときの前面のアプリ。覚えた結果を返すだけで、ここでは何も読まない
    static func current(app: String) -> Found? {
        guard Settings.repoContext, Settings.enterApps.contains(app) else { return nil }
        if app == "com.apple.Terminal" {
            guard let p = pressed, p.app == app, Date().timeIntervalSince(p.at) < keepSeconds else { return nil }
            return p.found
        }
        guard let r = remembered, r.app == app, Date().timeIntervalSince(r.at) < keepSeconds else { return nil }
        return r.found
    }

    // アクセシビリティの問い合わせを待つ上限（秒）
    static let axTimeout: Float = 0.3

    // Terminal.app の前面のウィンドウが今いるフォルダ（AXDocument は file:// の URL）
    static func terminalFolder(pid: pid_t) -> String? {
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, axTimeout)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &w) == .success, let w,
              CFGetTypeID(w) == AXUIElementGetTypeID() else { return nil }
        // 型 ID を確かめた後なので、そのまま AXUIElement として扱える
        let win = unsafeBitCast(w, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(win, axTimeout)
        var d: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXDocumentAttribute as CFString, &d) == .success,
              let s = d as? String, let u = URL(string: s), u.isFileURL else { return nil }
        return u.path
    }
}
