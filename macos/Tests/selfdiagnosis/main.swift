// test-sources: SelfDiagnosis.swift ../../Tests/TestSupport.swift
// make test: Sources/Koe/SelfDiagnosis.swift の単体テスト。数値と合成の音声だけを使う
import Foundation

// 合成の音声: 16 kHz の正弦波（0 を含まない）に、ちょうど 0 の連続を差し込む
func tone(_ n: Int, offset: Int = 0) -> [Int16] {
    (0..<n).map { i in
        let v = Int16(3000 * sin(Double(i + offset) * 0.3))
        return v == 0 ? 1 : v
    }
}
func withZeros(_ lengths: [Int]) -> [Int16] {
    var pcm: [Int16] = []
    for l in lengths { pcm += tone(1600); pcm += [Int16](repeating: 0, count: l) }
    return pcm + tone(1600)
}

// ゼロ連続: 50 ms (800 サンプル) 以上だけ数える
check(ZeroRuns.measure(tone(16000)) == ZeroRuns.Result(runs: 0, ratio: 0), "ゼロなし")
check(ZeroRuns.measure(withZeros([799])).runs == 0, "49.9 ms は数えない")
check(ZeroRuns.measure(withZeros([800])).runs == 1, "50 ms は数える")
let two = ZeroRuns.measure(withZeros([1600, 800]))
check(two.runs == 2 && two.ratio > 0.3 && two.ratio < 0.4, "2 か所: \(two)")
check(ZeroRuns.measure([Int16](repeating: 0, count: 16000)).runs == 0, "全部 0 は声ではない")
check(ZeroRuns.measure([]).runs == 0, "空")
let edges = [Int16](repeating: 0, count: 4000) + tone(3200) + [Int16](repeating: 0, count: 4000)
check(ZeroRuns.measure(edges).runs == 0, "前後の無音は数えない")

// 録音の列
func rec(level: Double = -20, snr: Double = 30, zeros: Int = 0, device: String = "mic",
         rate: Int = 16000, outcome: String = "pasted", fellBack: Bool = false) -> DiagRecording {
    DiagRecording(levelDB: level, noiseDB: level - snr, snrDB: snr, zeroRuns: zeros, device: device,
                  sampleRate: rate, fellBack: fellBack, outcome: outcome)
}
let normal = [DiagRecording](repeating: rec(), count: 20)
check(SelfDiagnosis.findings(normal).isEmpty, "普通の録音は何も出さない")

// 受け入れ: ゼロ連続は数回で検出され、文面が正しく、標準に戻すと確認で消える
var h = normal
h.append(rec(zeros: 3))
check(SelfDiagnosis.findings(h).isEmpty, "1 回だけでは出さない")
h.append(rec(zeros: 2))
var f = SelfDiagnosis.findings(h)
check(f.count == 1 && f[0].kind == .zeroRuns && !f[0].strong, "2 回で検出（弱）: \(f)")
check(f[0].fix.contains("標準") && f[0].fix.contains("声を分離"), "直し方の文面")
check(!f[0].message.contains("原因"), "原因とは言い切らない")
h.append(rec(zeros: 1))
f = SelfDiagnosis.findings(h)
check(f.first?.kind == .zeroRuns && f.first?.strong == true, "3 回で強い")
check(SelfDiagnosis.cleared(.zeroRuns, in: h) == false, "まだ直っていない")
h.append(rec()); h.append(rec())
check(SelfDiagnosis.cleared(.zeroRuns, in: h) == nil || SelfDiagnosis.cleared(.zeroRuns, in: h) == false, "2 回ではまだ")
h.append(rec())
check(SelfDiagnosis.cleared(.zeroRuns, in: h) == true, "標準に戻して 3 回で消える")

// 音量: 絶対値と、その機器のいつもより低い場合
var q = normal + [rec(level: -40), rec(level: -41)]
check(SelfDiagnosis.findings(q).first?.kind == .lowLevel, "-36 dB 未満")
q = normal + [rec(level: -30), rec(level: -31)]
check(SelfDiagnosis.findings(q).first?.kind == .lowLevel, "いつもより 8 dB 以上低い")
q = normal + [rec(level: -25), rec(level: -26)]
check(SelfDiagnosis.findings(q).isEmpty, "少し低いだけでは出さない")
let noBaseline = [rec(level: -30), rec(level: -31)]
check(SelfDiagnosis.findings(noBaseline).isEmpty, "基準がない（10 件未満）ときは絶対値だけ見る")
// 基準は別の機器の録音を使わない
let other = [DiagRecording](repeating: rec(level: -10, device: "other"), count: 20) + [rec(level: -25), rec(level: -26)]
check(SelfDiagnosis.findings(other).isEmpty, "別の機器の基準は使わない")

// SNR
let n = normal + [rec(snr: 15), rec(snr: 12)]
check(SelfDiagnosis.findings(n).first?.kind == .noisy, "SNR が基準より 10 dB 以上悪い")
check(SelfDiagnosis.findings(n).first?.fix.contains("静か") == true, "SNR の文面")

// 機器: 予備のマイクへの切り替わり、機器の変更、サンプルレートの変化、0 チャンネル
check(SelfDiagnosis.findings(normal + [rec(fellBack: true), rec(fellBack: true)]).first?.kind == .device, "予備へ切り替わり")
check(SelfDiagnosis.findings(normal + [rec(device: "usb"), rec(device: "mic")]).first?.kind == .device, "機器が行き来する")
check(SelfDiagnosis.findings(normal + [rec(rate: 48000), rec(rate: 48000)]).first?.kind == .device, "サンプルレート")
var zeroCh = rec(); zeroCh.channels = 0
check(SelfDiagnosis.findings(normal + [zeroCh, zeroCh]).first?.kind == .device, "0 チャンネル")

// 貼り付け: 直近 10 件のうち 3 件以上
let bad = [rec(outcome: "no_accessibility"), rec(outcome: "target_changed"), rec(outcome: "not_visible")]
f = SelfDiagnosis.findings(normal + bad)
check(f.count == 1 && f[0].kind == .paste && !f[0].strong, "貼り付け失敗 3 件: \(f)")
check(SelfDiagnosis.findings(normal + Array(bad.prefix(2))).isEmpty, "2 件では出さない")
check(SelfDiagnosis.findings(normal + bad + bad.prefix(2)).first?.strong == true, "5 件で強い")

// 複数あれば強いものが先
let mixed = normal + [rec(level: -40, zeros: 1), rec(level: -41, zeros: 1), rec(level: -42, zeros: 1)]
f = SelfDiagnosis.findings(mixed)
check(Set(f.map { $0.kind }) == [.zeroRuns, .lowLevel] && f.allSatisfy { $0.strong }, "複数: \(f.map { $0.kind })")

check(SelfDiagnosis.findings([]).isEmpty && SelfDiagnosis.cleared(.zeroRuns, in: []) == nil, "空の履歴")
check(SelfDiagnosis.median([1, 3, 2]) == 2 && SelfDiagnosis.median([1, 2, 3, 4]) == 2.5 && SelfDiagnosis.median([]) == nil, "中央値")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
