import Foundation

// 自己診断（#211）の履歴と、知らせ・再確認の判定。純粋な部分だけで AppKit を使わない（Tests/diagnosislog）。
// 保存するのは録音ごとの数値・マイクの名前・結果の名前だけ（文字起こし・音声・ウィンドウタイトルは持たない）。
// 「録音と結果を保存」がオフでも診断できるように、履歴とは別の小さなファイルに直近 maxKept 件だけ残す
enum DiagnosisLog {
    static let maxKept = 50

    /// 録音の数値から 1 件を作る。quality は AudioQuality.measure の結果
    static func recording(quality: [String: Any], zero: ZeroRuns.Result, device: String, sampleRate: Int,
                          fellBack: Bool, outcome: String) -> DiagRecording {
        DiagRecording(levelDB: quality["level_db"] as? Double, noiseDB: quality["noise_db"] as? Double,
                      snrDB: quality["snr_db"] as? Double, zeroRuns: zero.runs,
                      zeroRunRatio: (zero.ratio * 10000).rounded() / 10000, device: device,
                      sampleRate: sampleRate, channels: 1, fellBack: fellBack, outcome: outcome)
    }

    static func load(_ url: URL) -> [DiagRecording] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { try? dec.decode(DiagRecording.self, from: Data($0.utf8)) }
    }

    /// 1 件足して、直近 maxKept 件だけ残す。足した後の履歴を返す
    @discardableResult
    static func append(_ r: DiagRecording, to url: URL) -> [DiagRecording] {
        let all = Array((load(url) + [r]).suffix(maxKept))
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let lines = all.compactMap { (try? enc.encode($0)).flatMap { String(data: $0, encoding: .utf8) } }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return all
    }

    /// 1 日 1 回までの知らせに出す所見。強いものだけ、録音・文字起こし中は出さない。day は "yyyy-MM-dd"
    static func dailyNotice(_ findings: [DiagFinding], today: String, lastShownDay: String?, busy: Bool) -> DiagFinding? {
        guard !busy, lastShownDay != today else { return nil }
        return findings.first { $0.strong }
    }

    /// 「これで直った？」の再確認。kinds を確かめ始めてから新しく録った数が clearWindow に届いたら、
    /// 種類ごとに直ったかを返す（届くまでは nil）
    static func recheck(_ kinds: [DiagKind], newRecordings: Int, history: [DiagRecording]) -> [DiagKind: Bool]? {
        guard !kinds.isEmpty, newRecordings >= SelfDiagnosis.clearWindow else { return nil }
        var out: [DiagKind: Bool] = [:]
        for k in kinds { out[k] = SelfDiagnosis.cleared(k, in: history) ?? false }
        return out
    }

    /// 診断の画面に出す文面
    static func report(_ findings: [DiagFinding], count: Int) -> String {
        guard !findings.isEmpty else {
            return count == 0 ? "まだ録音がありません。何度か話してから、もう一度開いてください"
                              : "直近 \(count) 回の録音では、気になる所は見つかりませんでした"
        }
        return findings.map { "・\($0.message)（直近 \($0.window) 回中 \($0.affected) 回）\n　→ \($0.fix)" }
            .joined(separator: "\n\n")
    }

    static func recheckText(_ result: [DiagKind: Bool]) -> (title: String, detail: String) {
        let fixed = DiagKind.allCases.filter { result[$0] == true }
        let still = DiagKind.allCases.filter { result[$0] == false }
        if still.isEmpty { return ("直ったようです", fixed.map { SelfDiagnosis.text($0).message }.joined(separator: "、") + " は、直近の録音では出ていません") }
        return ("まだ直っていないようです", still.map { SelfDiagnosis.text($0).message }.joined(separator: "、") + "。メニューの「診断する…」で直し方を確かめてください")
    }
}
