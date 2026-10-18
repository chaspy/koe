// test-sources: PackSource.swift
// make test: unit tests for Sources/Koe/PackSource.swift (runs without XCTest)
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// gh: sources inside the allowlist
let g = PackSource.gitHub("gh:my-org/team.packs/voice/dev_v2-1.txt")
check(g == PackSource.GitHub(owner: "my-org", repo: "team.packs", path: "voice/dev_v2-1.txt"), "ordinary source: \(String(describing: g))")
check(PackSource.ghArguments(g!) == ["api", "repos/my-org/team.packs/contents/voice/dev_v2-1.txt", "-H", "Accept: application/vnd.github.raw"], "arguments")

// everything else is rejected
for bad in [
    "gh:a/b", "gh:/r/x.txt", "gh:o//x.txt", "gh:o/r/", "gh:o/r/../x.txt", "gh:o/r/./x.txt", "gh:o/r/a//x.txt",
    "gh:o/r/x.txt/", "gh:../r/x.txt", "gh:o/../x.txt", "gh:o w/r/x.txt", "gh:o/r;x/x.txt", "gh:o/r/x$y.txt",
    "gh:o/r/x?ref=1", "gh:o/r/x'y.txt", "gh:o/r/x\"y.txt", "gh:o/r/a`b`.txt", "gh:o/r/x|y.txt", "gh:o/r/x\ny.txt",
    "gh:o/r/名前.txt", "gh:\(String(repeating: "a", count: 40))/r/x.txt", "x:o/r/p",
] {
    check(PackSource.gitHub(bad) == nil, "accepted \(bad)")
}

// https only
check(PackSource.web("https://example.com/packs/dev.txt") != nil, "https")
check(PackSource.web("http://example.com/dev.txt") == nil, "http")
check(PackSource.web("file:///etc/hosts") == nil, "file")
check(PackSource.web("https:///x.txt") == nil, "no host")

// local file names
check(PackSource.cacheName("gh:o/r/voice/dev.txt") == "dev.txt", "cache name gh")
check(PackSource.cacheName("https://example.com/a/dev.txt") == "dev.txt", "cache name https")
check(PackSource.cacheName("gh:o/r/../dev.txt") == nil, "cache name rejected source")
check(PackSource.cacheName("https://example.com/..") == nil, "cache name dots")

// gh lookup: known locations first, then the login shell, absolute executables only
check(PackSource.resolveGh(home: "/h", isExecutable: { $0 == "/usr/local/bin/gh" }, loginShellLookup: { "/x/gh" }) == "/usr/local/bin/gh", "known location")
check(PackSource.resolveGh(home: "/h", isExecutable: { $0 == "/nix/bin/gh" }, loginShellLookup: { "/nix/bin/gh\n" }) == "/nix/bin/gh", "login shell")
check(PackSource.resolveGh(home: "/h", isExecutable: { _ in false }, loginShellLookup: { "/nix/bin/gh" }) == nil, "not executable")
check(PackSource.resolveGh(home: "/h", isExecutable: { $0 == "gh" }, loginShellLookup: { "gh" }) == nil, "relative path")
check(PackSource.resolveGh(home: "/h", isExecutable: { _ in false }, loginShellLookup: { nil }) == nil, "none")

// import dialog notice
check(PackSource.importNotice(packs: [], people: []).isEmpty, "no notice without sources")
let n = PackSource.importNotice(packs: ["gh:o/r/dev.txt", "gh:o/r/a b.txt"], people: ["https://example.com/p.tsv"])
check(n.contains("gh:o/r/dev.txt") && n.contains("https://example.com/p.tsv"), "lists sources")
check(n.components(separatedBy: "無視します").count == 2, "marks the unusable one only: \(n)")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("packsource: ok")
