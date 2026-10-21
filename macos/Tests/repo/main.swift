// test-sources: RepoContext.swift
// make test: Sources/Koe/RepoContext.swift の単体テスト（XCTest なしで動く）
import Foundation

// RepoContext.swift が使う main.swift の部品の代わり
enum Settings {
    static var repoContext = true
    static var enterApps = ["com.googlecode.iterm2", "com.apple.Terminal"]
}

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}
typealias F = RepoContext.Found

// ブランチの語: 決まった接頭辞・数字だけ・1 文字は省く
check(RepoContext.branchWords("feat/u12-repo-context") == ["u12", "repo", "context"], "\(RepoContext.branchWords("feat/u12-repo-context"))")
check(RepoContext.branchWords("main").isEmpty, "main")
check(RepoContext.branchWords("fix/123-a_b.payment") == ["payment"], "\(RepoContext.branchWords("fix/123-a_b.payment"))")
check(RepoContext.branchWords(nil).isEmpty, "nil")

// プロンプトに足す文字列
check(RepoContext.promptPart(nil) == "", "nil")
check(RepoContext.promptPart(F(repo: "koe-dev", branch: "main", source: "s")) == "koe-dev", "main は足さない")
check(RepoContext.promptPart(F(repo: "koe-dev", branch: "feat/u12-repo-context", source: "s")) == "koe-dev、u12、repo、context", "\(RepoContext.promptPart(F(repo: "koe-dev", branch: "feat/u12-repo-context", source: "s")))")
// 用語に既にある語・リポジトリ名と同じ語は省く（大文字小文字は区別しない）
check(RepoContext.promptPart(F(repo: "Koe", branch: "koe-Context", source: "s"), terms: ["context"]) == "Koe", "\(RepoContext.promptPart(F(repo: "Koe", branch: "koe-Context", source: "s"), terms: ["context"]))")
// 長すぎるときは語の切れ目で切る
let long = RepoContext.promptPart(F(repo: "service", branch: "feature/alpha-bravo-charlie-delta-echo-foxtrot-golf", source: "s"))
check(long.count <= RepoContext.maxChars && long.hasPrefix("service、alpha") && !long.hasSuffix("、"), "long: \(long)")
check(RepoContext.promptPart(F(repo: String(repeating: "x", count: 50), branch: nil, source: "s")) == "", "リポジトリ名だけで枠を超えるなら足さない")

// .git の読み方
check(RepoContext.headBranch("ref: refs/heads/feat/x\n") == "feat/x", "head")
check(RepoContext.headBranch("0123456789abcdef\n") == nil, "detached")
check(RepoContext.gitdirLine("gitdir: ../.git/worktrees/dev2\n") == "../.git/worktrees/dev2", "gitdir")
check(RepoContext.originName("[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:owner/my-repo.git\n\tfetch = x\n") == "my-repo", "ssh url")
check(RepoContext.originName("[remote \"upstream\"]\n\turl = https://github.com/a/up.git\n[remote \"origin\"]\n\turl = https://github.com/a/mine/\n") == "mine", "https url")
check(RepoContext.originName("[core]\n") == nil, "no origin")

// 実際のフォルダで: 普通のリポジトリと worktree
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("repo-test-\(UUID().uuidString)")
let fm = FileManager.default
func write(_ path: String, _ s: String) {
    let u = tmp.appendingPathComponent(path)
    do {
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try s.write(to: u, atomically: true, encoding: .utf8)
    } catch {
        print("FAIL: write \(path): \(error)"); exit(1)
    }
}
write("main/.git/HEAD", "ref: refs/heads/main\n")
write("main/.git/config", "[remote \"origin\"]\n\turl = git@github.com:owner/real-name.git\n")
write("main/.git/worktrees/wt/HEAD", "ref: refs/heads/feat/u12-repo-context\n")
write("main/.git/worktrees/wt/commondir", "../..\n")
write("wt/.git", "gitdir: ../main/.git/worktrees/wt\n")
write("wt/sub/dir/file", "")
write("plain/.git/HEAD", "ref: refs/heads/topic\n")
write("plain/.git/config", "[core]\n")
write("none/file", "")
let g1 = RepoContext.git(cwd: tmp.appendingPathComponent("main").path)
check(g1?.repo == "real-name" && g1?.branch == "main", "main: \(String(describing: g1))")
let g2 = RepoContext.git(cwd: tmp.appendingPathComponent("wt/sub/dir").path)
check(g2?.repo == "real-name" && g2?.branch == "feat/u12-repo-context", "worktree: \(String(describing: g2))")
let g3 = RepoContext.git(cwd: tmp.appendingPathComponent("plain").path)
check(g3?.repo == "plain" && g3?.branch == "topic", "origin なし: \(String(describing: g3))")
// 上にたどっても .git が無ければ nil（一時フォルダの上に .git がある環境は無い前提）
check(RepoContext.git(cwd: tmp.appendingPathComponent("none").path) == nil, "none")

// セッション記録: 貼った文が人の発話に入っている行の cwd と gitBranch（新しい行を優先）
let lines: [Substring] = [
    #"{"type":"user","cwd":"/a","gitBranch":"old","message":{"role":"user","content":"テストを回してください"}}"#,
    #"{"type":"assistant","cwd":"/a","message":{"content":[{"type":"text","text":"テストを回してください"}]}}"#,
    #"{"type":"user","cwd":"/b","gitBranch":"feat/x","message":{"role":"user","content":[{"type":"text","text":"では、テストを回してください。"}]}}"#,
    #"{"type":"user","cwd":"/c","gitBranch":"HEAD","message":{"role":"user","content":"別の話"}}"#,
    "壊れた行",
]
let m = RepoContext.sessionMatch(lines: lines, pasted: "テストを回して、ください")
check(m?.cwd == "/b" && m?.branch == "feat/x", "session: \(String(describing: m))")
check(RepoContext.sessionMatch(lines: lines, pasted: "別の話")?.branch == nil, "HEAD はブランチにしない")
check(RepoContext.sessionMatch(lines: lines, pasted: "はい") == nil, "短すぎる文では探さない")
check(RepoContext.sessionMatch(lines: lines, pasted: "どこにもない文です") == nil, "見つからない")

// findSession: 最近のファイルの末尾から
write("projects/p1/s.jsonl", lines.joined(separator: "\n") + "\n")
let f = RepoContext.findSession(pasted: "テストを回してください", root: tmp.appendingPathComponent("projects"))
check(f?.cwd == "/b", "findSession: \(String(describing: f))")

// 設定がオフ・ターミナル以外では何も返さない
Settings.repoContext = false
check(RepoContext.current(app: "com.googlecode.iterm2") == nil, "off")
Settings.repoContext = true
check(RepoContext.current(app: "com.tinyspeck.slackmacgap") == nil, "not a terminal")
check(RepoContext.current(app: "com.googlecode.iterm2") == nil, "まだ何も覚えていない")
check(RepoContext.current(app: "com.apple.Terminal") == nil, "Terminal: 録音を始めたときに読んでいない")
// 応答しないアプリ（存在しない pid）でも、すぐに nil で返る
let t0 = Date()
check(RepoContext.terminalFolder(pid: 999_999) == nil, "存在しない pid")
check(Date().timeIntervalSince(t0) < 1, "AX は待たない: \(Date().timeIntervalSince(t0))")

try? fm.removeItem(at: tmp)
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("repo: ok")
