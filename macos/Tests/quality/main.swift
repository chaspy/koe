// test-sources: AudioQuality.swift ../KoeAudioCore/koe_audio.cpp
// make test: Sources/Koe/AudioQuality.swift の単体テスト（声の大きさの指標と「声が小さい」の判定、#181）
import Foundation
import KoeAudioCore

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// 16 kHz。前後に 0.5 秒の静かな部分（部屋の雑音 ±noise）、間に dBFS の正弦波（RMS がその dBFS になる振幅）
func recording(speechDB: Double, seconds: Double, noise: Int16 = 3) -> [Int16] {
    var g = SystemRandomNumberGenerator()
    let quiet = (0..<8000).map { _ in Int16.random(in: -noise...noise, using: &g) }
    let amp = 32768 * pow(10, speechDB / 20) * 2.0.squareRoot()
    let tone = (0..<Int(seconds * 16000)).map { i in Int16(max(-32767, min(32767, amp * sin(2 * .pi * 220 * Double(i) / 16000)))) }
    return quiet + tone + quiet
}
func level(_ q: [String: Any]) -> Double { q["level_db"] as? Double ?? .nan }

// −50 dBFS の声: level_db が −45 より下に出て、知らせる（以前は −40 で切っていたので出なかった）
let soft = AudioQuality.measure(recording(speechDB: -50, seconds: 2))
check(abs(level(soft) + 50) < 1, "−50 dBFS is measured as about −50: \(soft)")
check(AudioQuality.tooQuiet(soft) != nil, "−50 dBFS warns")
check(abs((soft["speech_s"] as? Double ?? 0) - 2) < 0.1, "speech_s is the tone length: \(soft)")

// −25 dBFS（ふつうの声）: 知らせない
let normal = AudioQuality.measure(recording(speechDB: -25, seconds: 2))
check(abs(level(normal) + 25) < 1, "−25 dBFS is measured as about −25: \(normal)")
check(AudioQuality.tooQuiet(normal) == nil, "−25 dBFS does not warn")

// −44 dBFS（しきい値の少し上）: 知らせない。−46 は知らせる
check(AudioQuality.tooQuiet(AudioQuality.measure(recording(speechDB: -44, seconds: 2))) == nil, "−44 dBFS does not warn")
check(AudioQuality.tooQuiet(AudioQuality.measure(recording(speechDB: -46, seconds: 2))) != nil, "−46 dBFS warns")

// 短い音（0.2 秒。誤操作・キーの音）は小さくても知らせない
check(AudioQuality.tooQuiet(AudioQuality.measure(recording(speechDB: -50, seconds: 0.2))) == nil, "short sound does not warn")

// 背景の雑音だけ（声の部分なし）: 指標なし
check(AudioQuality.measure(recording(speechDB: -120, seconds: 1)).isEmpty, "noise only has no level")

// 小さすぎる音（−60 dBFS、下限の −56 より下）は声とみなさない
check(AudioQuality.measure(recording(speechDB: -60, seconds: 2)).isEmpty, "−60 dBFS is below the floor")

// 判定は値だけを見る
check(AudioQuality.tooQuiet(["level_db": -50.0, "speech_s": 1.0]) == -50, "dictionary: quiet")
check(AudioQuality.tooQuiet(["level_db": -50.0]) == nil, "no speech_s (older records): no warning")
check(AudioQuality.tooQuiet([:]) == nil, "empty")
check(AudioQuality.quietMessage(-50.4).contains("-50 dB"), "message shows the level: \(AudioQuality.quietMessage(-50.4))")

// Frozen outputs from the pre-unification Swift implementation, never generated from C++.
struct Golden: Decodable {
    let name: String
    let background_windows: Int
    let voice_windows: Int
    let amplitude: Int
    let background: Int
    let tail_samples: Int
    let quality: [String: Double]
    let too_quiet: Bool
}
let goldenURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../testdata/audio-quality.json").standardizedFileURL
let cases = try JSONDecoder().decode([Golden].self, from: Data(contentsOf: goldenURL))
for test in cases {
    let amplitudes = Array(repeating: test.background, count: test.background_windows)
        + Array(repeating: test.amplitude, count: test.voice_windows)
        + Array(repeating: test.background, count: test.background_windows)
    var pcm = amplitudes.flatMap { amplitude in
        (0..<480).map { Int16($0 % 2 == 0 ? amplitude : -amplitude) }
    }
    pcm += Array(repeating: 0, count: test.tail_samples)
    let measured = AudioQuality.measure(pcm)
    check(measured as? [String: Double] == test.quality, "golden metrics: \(test.name)")
    check((AudioQuality.tooQuiet(measured) != nil) == test.too_quiet, "golden quietness: \(test.name)")
}
// 取り込んだ koe-audio-core の C API の版（00fe10f から。リンクした実装とヘッダが揃っている）
check(koe_audio_api_version() == KOE_AUDIO_API_VERSION && KOE_AUDIO_API_VERSION == 1, "C API version")
if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("quality: ok (\(cases.count) Swift golden cases)")
