import Foundation

// whisper の窓（audio_ctx、50 フレーム = 1 秒）の大きさを発話の長さに合わせる。
// whisper のエンコーダーは audio_ctx を小さくしない限り毎回 30 秒ぶん全体を処理する。
// 式は Windows（windows/core/whisper.go の AutoAudioCtx）と同じ: 1 秒 50 フレームに 1 割と 64 フレームの余裕を足し、
// 768（15 秒ぶん）〜 1500 に収める。30 秒以上は全体（0）。
// Mac（turbo、Metal）では 10/16 の計測で中央値 −0.04 秒・p95 −0.10 秒、精度は同じだった。
// Windows で窓を縮めると文字が出なくなった turbo（CPU、q5_0）も、Mac では縮める
enum AudioWindow {
    static let auto = -1
    static let maxCtx = 1500  // 30 秒の窓
    static let minCtx = 768   // 15 秒。384 では短い発話で精度が落ちた（windows/bench/results.md）

    // 設定（audioCtx）の読み方: "auto"・未設定・読めない値・負の数は auto、0 は全体、1500 以上も全体、それ以外はそのフレーム数
    static func setting(_ v: Any?) -> Int {
        guard let n = (v as? NSNumber)?.intValue ?? (v as? String).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              n >= 0 else { return auto }
        return n >= maxCtx ? 0 : n
    }

    // whisper-server に送る audio_ctx（0 = 全体）
    static func ctx(setting: Int, seconds: Double) -> Int {
        setting == auto ? autoCtx(seconds: seconds) : setting
    }

    static func autoCtx(seconds: Double) -> Int {
        if seconds >= 30 { return 0 }
        let n = Int((seconds * 50 * 1.1 - 1e-9).rounded(.up)) + 64
        return min(maxCtx, max(minCtx, n))
    }
}
