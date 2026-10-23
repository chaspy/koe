// test-sources: ChimeSpan.swift
import Foundation

var failures = 0
func check(_ ok: Bool, _ message: String) {
    if !ok { failures += 1; print("FAIL: \(message)") }
}

// 合成数値だけを使い、音声・発話内容を保存しない。
for rate in [16000.0, 44100.0, 48000.0] {
    let start = Int(rate * 0.5) // プリロールはそのまま残す
    let end = start + Int(((0.12 + 0.080) * rate).rounded(.up))
    let input = (0..<Int(rate)).map { Int16($0 % 30000 + 1) }
    let output = ChimeSpan.silence(input, spans: [ChimeSpan(start: start, duration: 0.12)], sampleRate: rate)
    check(output.count == input.count, "length unchanged")
    check(Array(output[..<start]) == Array(input[..<start]), "pre-roll unchanged")
    check(output[start..<end].allSatisfy { $0 == 0 }, "duration plus 80ms silenced")
    check(Array(output[end...]) == Array(input[end...]), "following samples unchanged")
    check(input[start] != 0, "input not mutated")
}
let input = [Int16](repeating: 7, count: 100)
let spans = [ChimeSpan(start: 10, duration: 0.01), ChimeSpan(start: 50, duration: 0.02)]
let result = ChimeSpan.silence(input, spans: spans, sampleRate: 1000, margin: 0)
check(result == (0..<100).map { (10..<20).contains($0) || (50..<70).contains($0) ? Int16(0) : 7 },
      "start and later lock chime only")
let overlap = ChimeSpan.silence(input, spans: [ChimeSpan(start: 10, duration: 0.05),
                                             ChimeSpan(start: 40, duration: 0.10)], sampleRate: 1000, margin: 0)
check(overlap == [Int16](repeating: 7, count: 10) + [Int16](repeating: 0, count: 90), "overlap and end clipping")
check(ChimeSpan.silence([], spans: spans, sampleRate: 1000).isEmpty, "empty recording")
check(ChimeSpan.silence(input, spans: [], sampleRate: 1000) == input, "sounds disabled or play failed")
check(ChimeSpan.silence(input, spans: [ChimeSpan(start: 100, duration: 1)], sampleRate: 1000) == input,
      "chime beyond recording")
check(ChimeSpan.silence(input, spans: [ChimeSpan(start: 0, duration: 0.0001)], sampleRate: 1000, margin: 0)[0] == 0,
      "fractional sample rounds up")
for duration in [0.0, -1, Double.nan, Double.infinity] {
    check(ChimeSpan.silence(input, spans: [ChimeSpan(start: 0, duration: duration)], sampleRate: 1000) == input,
          "invalid duration unchanged")
}
for rate in [0.0, -1, Double.nan, Double.infinity] {
    check(ChimeSpan.silence(input, spans: spans, sampleRate: rate) == input, "invalid sample rate unchanged")
}
// hands-free の声検出に渡す分割バッファも、全体を無音化した場合と一致する。
let whole = ChimeSpan.silence(input, spans: spans, sampleRate: 1000, margin: 0)
let chunks = stride(from: 0, to: 100, by: 25).flatMap { offset in
    ChimeSpan.silence(Array(input[offset..<offset + 25]), offset: offset, spans: spans, sampleRate: 1000, margin: 0)
}
check(chunks == whole, "chunk coordinates match recording coordinates")
if failures > 0 { exit(1) }
print("chime: ok")
