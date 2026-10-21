// test-sources: Retention.swift
// make test: Sources/Koe/Retention.swift の単体テスト（XCTest なしで動く）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

let fm = FileManager.default
let fmt: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f }()
var comps = DateComponents(); comps.year = 2026; comps.month = 10; comps.day = 16; comps.hour = 12
let now = Calendar.current.date(from: comps)!
func dayAgo(_ n: Int) -> (String, Date) {
    let d = Calendar.current.date(byAdding: .day, value: -n, to: now)!
    return (fmt.string(from: d), d)
}
func tempDir() -> URL {
    let u = fm.temporaryDirectory.appendingPathComponent("koe-retention-\(UUID().uuidString)")
    try! fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
func put(_ dir: URL, _ day: String, _ name: String, _ size: Int, _ mod: Date) {
    let d = dir.appendingPathComponent(day)
    try? fm.createDirectory(at: d, withIntermediateDirectories: true)
    let f = d.appendingPathComponent(name)
    fm.createFile(atPath: f.path, contents: Data(count: size))
    try! fm.setAttributes([.modificationDate: mod], ofItemAtPath: f.path)
}
func left(_ dir: URL) -> String {
    var out: [String] = []
    for d in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []) {
        let u = dir.appendingPathComponent(d)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
            for f in (try? fm.contentsOfDirectory(atPath: u.path)) ?? [] { out.append("\(d)/\(f)") }
        } else { out.append(d) }
    }
    return out.sorted().joined(separator: " ")
}

// 日数
for (keep, text) in [(7, 14), (14, 30), (30, 60), (90, 180), (0, 0), (10, 20)] {
    check(Retention.textDays(keep) == text, "textDays(\(keep)) = \(Retention.textDays(keep))")
}
check(Retention.label(14).contains("既定") && Retention.label(0).contains("ずっと") && Retention.label(7).contains("14 日"), "labels")

// 日数で消す（14 日 / 30 日）
do {
    let dir = tempDir()
    defer { try? fm.removeItem(at: dir) }
    for n in [0, 1, 13, 14, 15, 29, 30, 31] {
        let (d, mod) = dayAgo(n)
        put(dir, d, "a.wav", 100, mod); put(dir, d, "a.alt.wav", 100, mod); put(dir, d, "a.json", 10, mod)
    }
    let (d40, mod40) = dayAgo(40)
    put(dir, d40, "b.wav", 100, mod40)
    put(dir, d40, "b.json", 10, now.addingTimeInterval(-3600)) // 改善ループが書き直したばかり
    fm.createFile(atPath: dir.appendingPathComponent("notes.txt").path, contents: Data("x".utf8))

    let dry = Retention.prune(dir: dir, keepDays: 14, now: now, dryRun: true)
    check(dry.audio == 9 && dry.text == 1 && left(dir).contains(dayAgo(31).0 + "/a.wav"), "dry run counts without removing: \(dry)")

    let r = Retention.prune(dir: dir, keepDays: 14, now: now)
    let got = left(dir)
    for n in [0, 1, 13, 14] { check(got.contains(dayAgo(n).0 + "/a.wav"), "recording of day -\(n) stays") }
    for n in [15, 29] {
        let d = dayAgo(n).0
        check(!got.contains(d + "/a.wav") && !got.contains(d + "/a.alt.wav") && got.contains(d + "/a.json"), "day -\(n): recordings removed, json kept")
    }
    check(!got.contains(dayAgo(31).0), "day -31 removed with its folder: \(got)")
    check(got.contains(dayAgo(30).0 + "/a.json"), "day -30 json stays")
    check(got.contains(d40 + "/b.json") && !got.contains(d40 + "/b.wav"), "a file changed within a day stays")
    check(got.contains("notes.txt"), "outside day folders untouched")
    check(r.audio == 9 && r.text == 1 && r.dirs == 1 && r.bytes == 910, "result \(r)")
}

// 空の日のフォルダ: 昨日と今日は残す（History.save が作ったばかりで、まだ録音を移していないことがある）。中身のあるフォルダは消さない
do {
    let dir = tempDir()
    defer { try? fm.removeItem(at: dir) }
    for n in [0, 1, 2, 40] { try? fm.createDirectory(at: dir.appendingPathComponent(dayAgo(n).0), withIntermediateDirectories: true) }
    let (d40, _) = dayAgo(41)
    put(dir, d40, "a.json", 10, now.addingTimeInterval(-60))
    let r = Retention.prune(dir: dir, keepDays: 14, now: now)
    let dirs = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    check(dirs.contains(dayAgo(0).0) && dirs.contains(dayAgo(1).0), "today and yesterday stay even when empty: \(dirs)")
    check(!dirs.contains(dayAgo(2).0) && !dirs.contains(dayAgo(40).0), "older empty folders removed: \(dirs)")
    check(dirs.contains(d40) && left(dir).contains(d40 + "/a.json"), "folder with a file stays")
    check(r.dirs == 2, "dirs \(r.dirs)")
}

// ずっと
do {
    let dir = tempDir()
    defer { try? fm.removeItem(at: dir) }
    let (d, mod) = dayAgo(400)
    put(dir, d, "a.wav", 100, mod)
    let r = Retention.prune(dir: dir, keepDays: 0, capBytes: 1, now: now)
    check(r.audio == 0 && left(dir).contains("a.wav") && r.sizeAfter == 100, "0 keeps everything: \(r)")
}

// 1GB（ここでは 3500 バイト）を超えたら古い録音から
do {
    let dir = tempDir()
    defer { try? fm.removeItem(at: dir) }
    for n in stride(from: 5, through: 0, by: -1) {
        let (d, mod) = dayAgo(n)
        put(dir, d, "a.wav", 1000, n == 0 ? now.addingTimeInterval(-60) : mod)
        put(dir, d, "a.json", 10, n == 0 ? now.addingTimeInterval(-60) : mod)
    }
    let r = Retention.prune(dir: dir, keepDays: 14, capBytes: 3500, now: now)
    let got = left(dir)
    check(r.audio == 3 && r.text == 0 && r.sizeAfter <= 3500, "cap: \(r)")
    check(!got.contains(dayAgo(5).0 + "/a.wav") && got.contains(dayAgo(5).0 + "/a.json"), "oldest recording first, json stays")
    _ = Retention.prune(dir: dir, keepDays: 14, capBytes: 1, now: now)
    check(left(dir).contains(dayAgo(0).0 + "/a.wav"), "today's recording is protected")
    let u = Retention.usage(dir)
    check(u.files > 0 && u.oldest == dayAgo(5).0, "usage \(u)")
}

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ok")
