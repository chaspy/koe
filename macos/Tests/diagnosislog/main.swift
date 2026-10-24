// test-sources: DiagnosisLog.swift SelfDiagnosis.swift ../../Tests/TestSupport.swift
// make test: Sources/Koe/DiagnosisLog.swift の単体テスト。一時ディレクトリと合成の数値だけを使う
import Foundation

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koe-diaglog-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: dir) }
let url = dir.appendingPathComponent("diagnosis.jsonl")

func rec(zero: Int = 0, outcome: String = "pasted") -> DiagRecording {
    DiagnosisLog.recording(quality: ["level_db": -24.0, "noise_db": -60.0, "snr_db": 36.0, "speech_s": 2.0],
                           zero: ZeroRuns.Result(runs: zero, ratio: zero > 0 ? 0.123456 : 0),
                           device: "MacBook Pro Microphone", sampleRate: 16000, fellBack: false, outcome: outcome)
}

// 作る: quality の数値を写し、割合は丸める
let r0 = rec(zero: 2)
check(r0.levelDB == -24 && r0.snrDB == 36 && r0.zeroRuns == 2 && r0.zeroRunRatio == 0.1235, "数値を写す: \(r0)")

// 保存と読み込み: 数値・機器・結果の名前だけ。上限で古いものから落とす
check(DiagnosisLog.load(url).isEmpty, "無いファイルは空")
for i in 0..<(DiagnosisLog.maxKept + 5) { DiagnosisLog.append(rec(zero: i % 2), to: url) }
let loaded = DiagnosisLog.load(url)
check(loaded.count == DiagnosisLog.maxKept, "直近 \(DiagnosisLog.maxKept) 件だけ: \(loaded.count)")
check(loaded.last == rec(zero: (DiagnosisLog.maxKept + 4) % 2), "読み戻すと同じ")
let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
let keys = Set(raw.split(separator: "\n").flatMap { line -> [String] in
    ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]).map { Array($0.keys) } ?? []
})
let allowed: Set<String> = ["level_db", "noise_db", "snr_db", "zero_runs", "zero_run_ratio", "device", "sample_rate",
                            "channels", "fell_back", "outcome"]
check(keys.isSubset(of: allowed), "許可したキーだけ: \(keys.subtracting(allowed))")

// 受け入れ条件: ゼロ連続のある録音が続くと数回で見つかり、直し方が正しい。標準に戻すと再確認で消える
var h: [DiagRecording] = (0..<10).map { _ in rec() }
check(SelfDiagnosis.findings(h).isEmpty, "普段は何も出ない")
h += [rec(zero: 3), rec(zero: 2)]
let f = SelfDiagnosis.findings(h)
check(f.first?.kind == .zeroRuns && f.first?.fix.contains("『標準』に戻して試してください") == true, "2 回で見つかる: \(f)")
h.append(rec(zero: 4))
let strong = SelfDiagnosis.findings(h)
check(strong.first?.strong == true, "3 回で強い所見")

// 1 日 1 回まで・録音中は出さない
check(DiagnosisLog.dailyNotice(strong, today: "2026-10-24", lastShownDay: nil, busy: false)?.kind == .zeroRuns, "強い所見は知らせる")
check(DiagnosisLog.dailyNotice(strong, today: "2026-10-24", lastShownDay: "2026-10-24", busy: false) == nil, "同じ日は 2 回出さない")
check(DiagnosisLog.dailyNotice(strong, today: "2026-10-25", lastShownDay: "2026-10-24", busy: false) != nil, "次の日はまた出す")
check(DiagnosisLog.dailyNotice(strong, today: "2026-10-24", lastShownDay: nil, busy: true) == nil, "録音中は出さない")
check(DiagnosisLog.dailyNotice(f, today: "2026-10-24", lastShownDay: nil, busy: false) == nil, "弱い所見は知らせない")

// 再確認: 3 回録るまでは判定しない。標準に戻した後の 3 回にゼロ連続が無ければ直った
check(DiagnosisLog.recheck([.zeroRuns], newRecordings: 2, history: h + [rec(), rec()]) == nil, "2 回では判定しない")
check(DiagnosisLog.recheck([.zeroRuns], newRecordings: 3, history: h + [rec(), rec(), rec()]) == [.zeroRuns: true], "直った")
check(DiagnosisLog.recheck([.zeroRuns], newRecordings: 3, history: h + [rec(), rec(zero: 1), rec()]) == [.zeroRuns: false], "まだ")
check(DiagnosisLog.recheck([], newRecordings: 5, history: h) == nil, "確かめていなければ何もしない")
check(DiagnosisLog.recheckText([.zeroRuns: true]).title == "直ったようです", "直った文面")
check(DiagnosisLog.recheckText([.zeroRuns: false]).title == "まだ直っていないようです", "まだの文面")

// 診断の文面
check(DiagnosisLog.report([], count: 0).contains("まだ録音がありません"), "録音なし")
check(DiagnosisLog.report([], count: 10).contains("見つかりませんでした"), "所見なし")
check(DiagnosisLog.report(strong, count: 10).contains("直近 5 回中 3 回"), "回数を出す: \(DiagnosisLog.report(strong, count: 10))")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("diagnosislog: ok")
