import Foundation

// 音質の客観指標（発話ごとに記録し、伝達の失敗との関係やマイクの比較に使う）
//   level_db: 声の部分の平均 RMS（dBFS）/ noise_db: 背景（静かな窓の下位 10%）/ snr_db: 差
//   speech_s: 声の部分の長さ（秒）
//   clip_ratio: 振幅が上限付近に張り付いた割合 / brightness: 高い音の成分の比（こもるほど小さい）
// 声の部分は、背景より 10 dB 以上大きい 30 ms の窓（ただし −56 dBFS 以上）。
// 以前は録音の「声あり」と同じ RMS 330（約 −40 dBFS）で切っていたため level_db が −40 より下にならず、
// 「声が小さい」（−45 dB 未満）の知らせが出なかった（#181）
enum AudioQuality {
    static let window = 480            // 30 ms
    static let speechFloor = 50.0      // 約 −56 dBFS。これより小さい窓は背景が静かでも声とみなさない
    static let speechOverNoise = 3.16  // 背景（下位 10%）より 10 dB
    static let quietDB = -45.0         // これより小さい声は入力音量の案内を出す
    static let quietMinSpeech = 0.3    // 声の部分がこれ以上あるときだけ（誤操作・キーの音で出さない）

    static func measure(_ pcm: [Int16]) -> [String: Any] {
        let win = window
        guard pcm.count > win * 4 else { return [:] }
        var rms: [Double] = []
        var i = 0
        while i + win <= pcm.count {
            var sum = 0.0
            for j in i..<i + win { let v = Double(pcm[j]); sum += v * v }
            rms.append((sum / Double(win)).squareRoot())
            i += win
        }
        let sorted = rms.sorted()
        let noise = max(sorted[sorted.count / 10], 1)
        let gate = max(noise * speechOverNoise, speechFloor)
        let voiced = rms.filter { $0 > gate }
        guard !voiced.isEmpty else { return [:] }
        let speech = voiced.reduce(0, +) / Double(voiced.count)
        func db(_ x: Double) -> Double { (20 * log10(x / 32768) * 10).rounded() / 10 }
        let clip = Double(pcm.filter { abs(Int($0)) >= 32000 }.count) / Double(pcm.count)
        var e = 0.0, d = 0.0
        for k in 1..<pcm.count { let a = Double(pcm[k]), b = Double(pcm[k - 1]); e += a * a; d += (a - b) * (a - b) }
        return [
            "level_db": db(speech), "noise_db": db(noise), "snr_db": ((20 * log10(speech / noise)) * 10).rounded() / 10,
            "speech_s": (Double(voiced.count * win) / 16000 * 100).rounded() / 100,
            "clip_ratio": (clip * 10000).rounded() / 10000, "brightness": e > 0 ? ((d / e) * 1000).rounded() / 1000 : 0,
        ]
    }

    // 声が小さく録れているなら、その level_db。そうでなければ nil
    static func tooQuiet(_ q: [String: Any]) -> Double? {
        guard let l = q["level_db"] as? Double, l < quietDB,
              (q["speech_s"] as? Double ?? 0) >= quietMinSpeech else { return nil }
        return l
    }

    static func quietMessage(_ level: Double) -> String {
        String(format: "声が小さく録れています（%.0f dB）。システム設定 → サウンド → 入力 で入力音量を上げるか、マイクを口元に近づけてください", level)
    }
}
