// test-sources: SyncedTerms.swift
// make test: unit tests for Sources/Koe/SyncedTerms.swift (runs without XCTest)
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// Ordinary terms are usable
for term in ["プルリクエスト", "GitHub", "Claude Code", "Node.js", "CI/CD", "C++", "e-mail", "v1.2_rc", "👨‍👩‍👧", "a b c"] {
    check(SyncedTerms.usable(term), "usable: \(term)")
}
// Long, multi-space, control or shell metacharacters are not
for term in [
    "", String(repeating: "あ", count: 41), "a b c d", "line\nbreak", "tab\there", "esc\u{1B}", "rtl\u{202E}x",
    "a;b", "a|b", "a&b", "a$b", "a`b`", "(a)", "a>b", "a<b", "a\\b", "\"q\"", "'q'", "a*", "a?", "!a", "~a", "C#", "{a}", "[a]",
] {
    check(!SyncedTerms.usable(term), "not usable: \(term.debugDescription)")
}
check(SyncedTerms.usable(String(repeating: "あ", count: 40)), "40 characters")

// Which pack files are synced
let dir = URL(fileURLWithPath: "/Users/x/Library/Application Support/Koe/packs")
let sources = ["gh:o/r/voice/team.txt", "https://example.com/p/shared.txt"]
check(SyncedTerms.isSynced(packURL: dir.appendingPathComponent("team.txt"), userPacksDir: dir, sources: sources), "gh copy")
check(SyncedTerms.isSynced(packURL: dir.appendingPathComponent("shared.txt"), userPacksDir: dir, sources: sources), "https copy")
check(!SyncedTerms.isSynced(packURL: dir.appendingPathComponent("mine.txt"), userPacksDir: dir, sources: sources), "hand-placed pack")
check(!SyncedTerms.isSynced(packURL: URL(fileURLWithPath: "/Applications/Koe.app/Contents/Resources/packs/team.txt"), userPacksDir: dir, sources: sources), "bundled pack with the same name")
check(!SyncedTerms.isSynced(packURL: dir.appendingPathComponent("team.txt"), userPacksDir: dir, sources: []), "no sources")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("syncedterms: ok")
