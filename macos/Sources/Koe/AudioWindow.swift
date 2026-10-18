import Foundation

// whisper の窓（audio_ctx、50 フレーム = 1 秒）の大きさを発話の長さに合わせる。
// whisper のエンコーダーは audio_ctx を小さくしない限り毎回 30 秒ぶん全体を処理する。
// 式は Windows（windows/core/whisper.go の AutoAudioCtx）と同じ: 1 秒 50 フレームに 1 割と 64 フレームの余裕を足し、
// 768（15 秒ぶん）〜 1500 に収める。30 秒以上は全体（0）。
// Mac（turbo、Metal）では 10/16 の計測で中央値 −0.04 秒・p95 −0.10 秒、精度は同じだった。
// Windows で窓を縮めると文字が出なくなった turbo（CPU、q5_0）も、Mac では縮める
//
// #165: 公開データ（JSUT）を長さ別に測り直すと、縮めた窓はどの長さでも全体より CER が高く、
// 7.5〜20 秒では発話の 2〜5 割が読めない文になった（12.8〜16 秒で CER 55% 対 6%。
// eval/audio_ctx_bench.py、docs/notes/2026-10-18-audio-ctx-by-length.md）。
// そこで Mac の auto は shrinkBelowSeconds 未満の発話だけ縮める。既定の 0 は「縮めない」＝毎回全体。
// 5 秒未満なら CER の差は 0.3 ポイントで、中央値は 0.25 秒速いので、速さを取るなら 7.5 にする
enum AudioWindow {
    static let auto = -1
    static let maxCtx = 1500  // 30 秒の窓
    static let minCtx = 768   // 15 秒。384 では短い発話で精度が落ちた（windows/bench/results.md）
    static let shrinkBelowSeconds = 0.0  // auto で窓を縮める発話の長さの上限（0 = 縮めない）

    // 設定（audioCtx）の読み方: "auto"・未設定・読めない値・負の数は auto、0 は全体、1500 以上も全体、それ以外はそのフレーム数
    static func setting(_ v: Any?) -> Int {
        guard let n = (v as? NSNumber)?.intValue ?? (v as? String).flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              n >= 0 else { return auto }
        return n >= maxCtx ? 0 : n
    }

    // whisper-server に送る audio_ctx（0 = 全体）
    static func ctx(setting: Int, seconds: Double, shrinkBelow: Double = shrinkBelowSeconds) -> Int {
        guard setting == auto else { return setting }
        return seconds < shrinkBelow ? autoCtx(seconds: seconds) : 0
    }

    // 長さに合わせた窓（Windows の AutoAudioCtx と同じ式）

    static func autoCtx(seconds: Double) -> Int {
        if seconds >= 30 { return 0 }
        let n = Int((seconds * 50 * 1.1 - 1e-9).rounded(.up)) + 64
        return min(maxCtx, max(minCtx, n))
    }

    // 縮めた窓の出力が崩れているか（#165）。崩れていれば理由、そうでなければ nil。
    // 日本語の要求で、日本語（かな・漢字・記号）とラテン文字以外の文字（ハングル・キリル文字など）が出た、
    // または応答が UTF-8 として読めなかった（U+FFFD）。中国語の簡体字は漢字なので見分けない
    static func garbledReason(_ text: String) -> String? {
        if text.unicodeScalars.contains("\u{FFFD}") { return "invalid_utf8" }
        if text.unicodeScalars.contains(where: { $0.properties.isAlphabetic && !japaneseOrLatin($0.value) }) {
            return "foreign_script"
        }
        return nil
    }

    // 読めなかったバイト（U+FFFD）は意味を持たないので、貼る前に落とす
    static func dropInvalid(_ text: String) -> String {
        text.unicodeScalars.contains("\u{FFFD}") ? String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\u{FFFD}" })) : text
    }

    private static func japaneseOrLatin(_ v: UInt32) -> Bool {
        switch v {
        case 0x0000...0x024F, 0x1E00...0x1EFF,      // ラテン文字（アクセント付きを含む）
             0x3000...0x30FF, 0x31F0...0x31FF,      // 記号・ひらがな・カタカナ
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFF,  // 漢字
             0xFF00...0xFFEF:                       // 全角・半角
            return true
        default:
            return false
        }
    }
}
