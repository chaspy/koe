import Foundation
import KoeAudioCore

// The imported C API is the single implementation of audio quality and quietness.
// PCM is mono, 16 kHz, and includes the recording's background windows.
enum AudioQuality {
    static func measure(_ pcm: [Int16]) -> [String: Any] {
        var quality = koe_quality()
        let result = pcm.withUnsafeBufferPointer {
            koe_measure_i16($0.baseAddress, $0.count, 16000, &quality)
        }
        guard result == KOE_OK, quality.valid != 0 else { return [:] }
        return ["level_db": quality.level_db, "noise_db": quality.noise_db,
                "snr_db": quality.snr_db, "speech_s": quality.speech_s,
                "clip_ratio": quality.clip_ratio, "brightness": quality.brightness]
    }

    static func tooQuiet(_ values: [String: Any]) -> Double? {
        guard let level = values["level_db"] as? Double else { return nil }
        var quality = koe_quality()
        quality.valid = 1
        quality.level_db = level
        quality.speech_s = values["speech_s"] as? Double ?? 0
        return koe_too_quiet(&quality) != 0 ? level : nil
    }

    static func quietMessage(_ level: Double) -> String {
        String(format: "声が小さく録れています（%.0f dB）。システム設定 → サウンド → 入力 で入力音量を上げるか、マイクを口元に近づけてください", level)
    }
}
