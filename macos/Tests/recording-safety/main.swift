// test-sources: RecordingSafety.swift RecordingArchive.swift RetryList.swift PressGesture.swift
import Foundation

func check(_ value: Bool, _ message: String) {
    if !value { print("FAIL: \(message)"); exit(1) }
}
let rate = 16000
let first = [Int16](repeating: 1000, count: 30 * rate)
let second = [Int16](repeating: 2000, count: 30 * rate)
let silent = [Int16](repeating: 0, count: 30 * rate)
let voice: ([Int16]) -> Bool = { $0.contains { $0 != 0 } }
// Device replacement, fallback, and a failed reopen retain all preceding samples.
let preserved = RecordingSafety.choose([silent, first], hasVoice: voice)
let combined = preserved + RecordingSafety.choose([second], hasVoice: voice)
check(combined.count == 60 * rate && combined.first == 1000 && combined.last == 2000, "device generations keep 60 seconds in order")
check(preserved + RecordingSafety.choose([], hasVoice: voice) == first, "failed device reopen retains preceding audio")
check(!RecordingSafety.startsNewPress(pressed: true, wasDown: true), "duplicate down does not replace utterance")
check(RecordingSafety.startsNewPress(pressed: true, wasDown: false), "real press starts")
check(!RecordingSafety.cancelForMouse(held: 60, seconds: 60), "click during 60 second hold keeps recording")
check(!RecordingSafety.cancelForMouse(held: 0.2, seconds: 60), "replaced press timestamp cannot discard old audio")
for elapsed in [60.0, 300, 600] {
    check(PressGesture.watch(elapsed: elapsed, sinceVoice: nil, keyDown: true) == .keep, "watch cannot stop while held")
    check(PressGesture.watch(elapsed: elapsed, sinceVoice: 60, keyDown: true) == .keep, "silence cannot stop while held")
}
for seconds in [2.001, 60, 300] {
    check(RecordingSafety.mustKeep(seconds: seconds, saveHistory: true), "long audio retained")
    check(!RecordingSafety.mustKeep(seconds: seconds, saveHistory: false), "disabled history does not retain long audio")
    check(!RecordingSafety.mustKeep(seconds: 0.2, held: seconds, saveHistory: false), "long hold cannot override disabled history")
    for enabled in [false, true] {
        for reason in ["mouse", "key 12", "hands_free_no_voice", "application_quit"] {
            check(!RetryList.keepCancelled(enabled: enabled, held: seconds, reason: reason, saveHistory: false), "cancellation respects disabled history")
        }
    }
    check(RetryList.keepCancelled(enabled: false, held: seconds, reason: "mouse", saveHistory: true), "enabled history protects long audio")
}
check(!RecordingSafety.mustKeep(seconds: 2, saveHistory: true), "two second boundary")

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let source = root.appendingPathComponent("source.wav")
// Synthetic PCM only; no microphone or running app is used.
let pcm = RecordingArchive.wavData(combined, sampleRate: rate)
check(pcm.count == 44 + 60 * rate * 2, "complete 60 second WAV")
check(String(data: pcm.prefix(4), encoding: .ascii) == "RIFF", "WAV header")
try pcm.write(to: source)
let id = "2026-10-28T12-00-00-000"
let history = root.appendingPathComponent("history")
try RecordingArchive.save(root: history, id: id, wav: source, record: ["outcome": "pending", "audio_seconds": 60.0])
let day = history.appendingPathComponent("2026-10-28")
check(try Data(contentsOf: day.appendingPathComponent(id + ".wav")) == pcm, "audio exists before server restart or response")
check(fm.fileExists(atPath: source.path), "archive copy preserves source")
guard let record = try JSONSerialization.jsonObject(with: Data(contentsOf: day.appendingPathComponent(id + ".json"))) as? [String: Any] else {
    print("FAIL: archive metadata missing"); exit(1)
}
// Use the same local timestamp parser as the history list.
let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
let localNow = formatter.date(from: id)!.addingTimeInterval(60)
for outcome in ["pending", "cancelled", "error", "no_voice", "mic_silent"] {
    var row = record; row["outcome"] = outcome; row["locked"] = true
    check(RetryList.items([row], now: localNow) { _, _ in true }.count == 1, "interrupted and locked audio is retryable")
}
// A name collision or unwritable destination must not consume the only source.
do {
    try RecordingArchive.save(root: history, id: id, wav: source, record: [:])
    check(false, "collision must fail")
} catch { check(try Data(contentsOf: source) == pcm, "collision preserves original") }
let blocked = root.appendingPathComponent("blocked")
try Data([0]).write(to: blocked)
do {
    try RecordingArchive.save(root: blocked, id: id, wav: source, record: [:])
    check(false, "invalid destination must fail")
} catch { check(try Data(contentsOf: source) == pcm, "write failure preserves original") }
print("recording-safety: ok")
