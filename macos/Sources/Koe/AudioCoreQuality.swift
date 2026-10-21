import Foundation
import KoeAudioCore

// 音質の判定の C++ 版（KoeAudioCore、koe-audio-core から取り込み）。Settings.audioCore がオンのときだけ使う。
// オンでも Swift 版（AudioQuality）を並べて計算し、値が違えば events に数値だけ残す（発話の本文・パスは書かない）。
enum AudioCoreQuality {
    static let fields = ["level_db", "noise_db", "snr_db", "speech_s", "clip_ratio", "brightness"]

    // AudioQuality.measure と同じ形の辞書。声の部分がない・失敗したときは空
    static func measureCore(_ pcm: [Int16]) -> [String: Any] {
        var q = koe_quality()
        let rc = pcm.withUnsafeBufferPointer { koe_measure_i16($0.baseAddress, $0.count, 16000, &q) }
        guard rc == KOE_OK, q.valid != 0 else { return [:] }
        return ["level_db": q.level_db, "noise_db": q.noise_db, "snr_db": q.snr_db,
                "speech_s": q.speech_s, "clip_ratio": q.clip_ratio, "brightness": q.brightness]
    }

    // 2 つの結果で値が違う項目の「差」（数値だけ）。同じなら空。片方だけ空のときは "empty_mismatch"
    static func diff(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        if a.isEmpty != b.isEmpty { return ["empty_mismatch": true] }
        var d: [String: Any] = [:]
        for k in fields {
            let x = a[k] as? Double ?? 0, y = b[k] as? Double ?? 0
            if abs(x - y) > 1e-9 { d[k] = ((y - x) * 10000).rounded() / 10000 }
        }
        return d
    }

    // log は差があったときだけ呼ぶ（main.swift が Events.log("audio_core_diff", …) を渡す）
    static func measure(_ pcm: [Int16], log: ([String: Any]) -> Void) -> [String: Any] {
        let core = measureCore(pcm)
        let d = diff(AudioQuality.measure(pcm), core)
        if !d.isEmpty { log(d) }
        return core
    }
}
