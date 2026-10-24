import Foundation

// Self-diagnosis detectors (#211). Pure functions over per-recording numbers: nothing here reads
// audio files, transcripts, window titles or the clipboard, and nothing is logged or sent.
// The menu, the daily notice and the agent bundle build on these in later slices.

/// Exact-zero runs inside the voiced part of a recording. Digital silence in the middle of speech is
/// what some noise-removal modes leave behind; it also makes the noise floor look unrealistically
/// low (-90 dB), which reads as a better SNR.
enum ZeroRuns {
    struct Result: Equatable {
        var runs: Int          // runs of exact zeros at least `minMs` long
        var ratio: Double      // share of the voiced span covered by those runs (0...1)
    }

    /// Leading and trailing zeros are ignored (the span starts at the first and ends at the last
    /// non-zero sample), so a recording that merely starts or ends in silence is not flagged.
    static func measure(_ pcm: [Int16], sampleRate: Int = 16000, minMs: Int = 50) -> Result {
        guard sampleRate > 0, let first = pcm.firstIndex(where: { $0 != 0 }),
              let last = pcm.lastIndex(where: { $0 != 0 }) else { return Result(runs: 0, ratio: 0) }
        let minLen = max(1, sampleRate * minMs / 1000)
        var runs = 0, covered = 0, current = 0
        for i in first...last {
            if pcm[i] == 0 { current += 1; continue }
            if current >= minLen { runs += 1; covered += current }
            current = 0
        }
        return Result(runs: runs, ratio: Double(covered) / Double(last - first + 1))
    }
}

/// What the detectors know about one recording. Numbers, a device identifier and an outcome name only.
struct DiagRecording: Equatable, Codable {
    var levelDB: Double?
    var noiseDB: Double?
    var snrDB: Double?
    var zeroRuns: Int = 0
    var zeroRunRatio: Double = 0
    var device: String = ""
    var sampleRate: Int = 16000
    var channels: Int = 1
    var fellBack: Bool = false       // the preferred input was unavailable and a spare one was used
    var outcome: String = "pasted"

    // 保存するキー（DiagnosisLog）。ここに無いものは書かない
    enum CodingKeys: String, CodingKey {
        case levelDB = "level_db", noiseDB = "noise_db", snrDB = "snr_db", zeroRuns = "zero_runs"
        case zeroRunRatio = "zero_run_ratio", device, sampleRate = "sample_rate", channels
        case fellBack = "fell_back", outcome
    }
}

enum DiagKind: String, CaseIterable {
    case zeroRuns, lowLevel, noisy, device, paste
}

struct DiagFinding: Equatable {
    var kind: DiagKind
    var affected: Int      // recordings in the window showing it
    var window: Int        // recordings looked at
    var strong: Bool       // worth the (at most daily) proactive notice
    var message: String
    var fix: String
}

enum SelfDiagnosis {
    static let recentWindow = 5
    static let pasteWindow = 10
    static let clearWindow = 3
    static let absoluteQuietDB = -36.0
    static let quieterThanUsualDB = 8.0
    static let snrDropDB = 10.0
    static let minBaseline = 10
    static let badOutcomes: Set<String> = ["no_accessibility", "target_changed", "not_visible"]

    struct Baseline: Equatable {
        var levelDB: Double?
        var snrDB: Double?
        var sampleRate: Int?
    }

    /// Per-device baseline from the recordings older than the window being judged, so a problem that
    /// has just started cannot become the "usual" level. Needs `minBaseline` recordings on the device.
    static func baseline(for device: String, in older: [DiagRecording]) -> Baseline {
        let same = older.filter { $0.device == device }
        guard same.count >= minBaseline else { return Baseline() }
        return Baseline(levelDB: median(same.compactMap { $0.levelDB }),
                        snrDB: median(same.compactMap { $0.snrDB }),
                        sampleRate: same.last?.sampleRate)
    }

    /// Whether one recording shows `kind`. `previous` is the recording before it (device changes).
    static func affected(_ kind: DiagKind, _ r: DiagRecording, previous: DiagRecording?, baseline b: Baseline) -> Bool {
        switch kind {
        case .zeroRuns:
            return r.zeroRuns > 0
        case .lowLevel:
            guard let level = r.levelDB else { return false }
            if level < absoluteQuietDB { return true }
            if let usual = b.levelDB { return level < usual - quieterThanUsualDB }
            return false
        case .noisy:
            guard let snr = r.snrDB, let usual = b.snrDB else { return false }
            return snr < usual - snrDropDB
        case .device:
            if r.fellBack || r.channels <= 0 || r.sampleRate <= 0 { return true }
            if let p = previous, !p.device.isEmpty, !r.device.isEmpty, p.device != r.device { return true }
            if let rate = b.sampleRate { return r.sampleRate != rate }
            return false
        case .paste:
            return badOutcomes.contains(r.outcome)
        }
    }

    /// For each of the last `n` recordings, whether it shows `kind` (oldest first).
    static func flags(_ kind: DiagKind, last n: Int, in history: [DiagRecording]) -> [Bool] {
        let count = min(n, history.count)
        let start = history.count - count
        let older = Array(history[..<max(0, history.count - max(n, recentWindow))])
        return (start..<history.count).map { i in
            affected(kind, history[i], previous: i > 0 ? history[i - 1] : nil,
                     baseline: baseline(for: history[i].device, in: older))
        }
    }

    /// Findings for the history (oldest first), strongest first. Empty when nothing stands out.
    static func findings(_ history: [DiagRecording]) -> [DiagFinding] {
        var out: [DiagFinding] = []
        for kind in DiagKind.allCases {
            let window = kind == .paste ? pasteWindow : recentWindow
            let f = flags(kind, last: window, in: history)
            let hits = f.filter { $0 }.count
            let need = kind == .paste ? 3 : 2
            let strongAt = kind == .paste ? 5 : 3
            guard hits >= need else { continue }
            let (message, fix) = text(kind)
            out.append(DiagFinding(kind: kind, affected: hits, window: f.count, strong: hits >= strongAt,
                                   message: message, fix: fix))
        }
        return out.sorted { ($0.strong ? 1 : 0, $0.affected) > ($1.strong ? 1 : 0, $1.affected) }
    }

    /// The re-check after the user tried a fix: cleared when the last few recordings do not show it.
    /// Nil until enough new recordings exist.
    static func cleared(_ kind: DiagKind, in history: [DiagRecording]) -> Bool? {
        guard history.count >= clearWindow else { return nil }
        return !flags(kind, last: clearWindow, in: history).contains(true)
    }

    // Wording: something to try, never a claim about the cause (whether zero runs hurt whisper is #197).
    static func text(_ kind: DiagKind) -> (message: String, fix: String) {
        switch kind {
        case .zeroRuns:
            return ("録音の中に音が途切れる所があります",
                    "マイクモードが『声を分離』になっているか、ノイズを消すアプリが入っていれば、『標準』に戻して試してください")
        case .lowLevel:
            return ("声が小さく録れています", "マイクを口元に近づけてください")
        case .noisy:
            return ("周りの音が大きいようです", "静かな場所に移るか、マイクを口元に近づけてください")
        case .device:
            return ("使っているマイクが途中で変わっています", "メニューで使いたいマイクを選び直してください")
        case .paste:
            return ("貼り付けがうまくいかないことが続いています", "アクセシビリティの許可と、貼り付け先のウィンドウを確認してください")
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
