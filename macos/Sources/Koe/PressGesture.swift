import Foundation

// 押し方の判定（U-9）
// - auto: 短く押したら（tapMax 未満）手を離して話せる録音になり、もう一度押すと終えて貼る。長押しは今までどおり押している間だけ録る
//   素早く 2 回押す（タップの後 doubleTapGap 以内に、もう一度短く押す）とロック録音（貼らずにテキストに書き出す）
// - hold（既定）: 押している間だけ録る。短すぎる押下は捨て、素早く 2 回押すとロック録音
// - toggle: 前からあるトグル。短く押すと開始、もう一度押すと終えて貼る（2 回押しのロックは無い）
// auto で手を離して録っている間は、声が来ないまま・黙ったまま・長すぎるときに自分で止める（録りっぱなしにしない）。
// toggle は今までどおり、もう一度押すまで止めない
enum PressGesture {
    enum Mode: String { case auto, hold, toggle }

    static let tapMax = 0.3
    static let toggleTapMax = 0.5
    static let doubleTapGap = 0.5

    // 手を離して録っている間の止め方
    static let noVoiceLimit = 8.0    // 押してからこの間に声が無ければ、誤って触れたとみなして黙って捨てる
    static let silenceLimit = 60.0   // 話した後この間ずっと黙っていたら、終えて貼る
    static let maxSeconds = 300.0    // 長くてもここで終えて貼る（長い話はロック録音へ）

    // 新しい押し方（auto）は既定オフ。設定 pressMode = auto で使う
    static func mode(_ raw: String?) -> Mode { Mode(rawValue: raw ?? "") ?? .hold }

    enum Release: Equatable { case paste, handsFree, lock, tooShort }

    // 録音していないところから押して離したとき。sinceLastTap は前のタップを離してから今回押すまでの秒数
    static func firstRelease(mode: Mode, held: Double, minHold: Double, sinceLastTap: Double) -> Release {
        switch mode {
        case .auto: return held < tapMax ? .handsFree : .paste
        case .toggle: return held < toggleTapMax ? .handsFree : .paste
        case .hold:
            if held >= minHold { return .paste }
            return sinceLastTap < doubleTapGap ? .lock : .tooShort
        }
    }

    // 手を離して録っている途中に、もう一度押して離したとき。gap はタップを離してから今回押すまでの秒数。
    // auto では、タップのすぐ後の短いタップは 2 回押し（ロック録音に切り替える）。それ以外は終えて貼る
    static func secondRelease(mode: Mode, held: Double, gap: Double) -> Release {
        mode == .auto && held < tapMax && gap < doubleTapGap ? .lock : .paste
    }

    // 自分で止める見張りをかけるか（auto だけ。hold・toggle は今と同じ動き）
    static func autoStops(_ mode: Mode) -> Bool { mode == .auto }

    enum Watch: String { case keep, discard, silence, tooLong = "too_long" }

    // elapsed は押してからの秒数、sinceVoice は最後に声が来てからの秒数（まだ声が無ければ nil）
    static func watch(elapsed: Double, sinceVoice: Double?, keyDown: Bool = false) -> Watch {
        guard !keyDown else { return .keep }
        if elapsed >= maxSeconds { return .tooLong }
        guard let s = sinceVoice else { return elapsed >= noVoiceLimit ? .discard : .keep }
        return s >= silenceLimit ? .silence : .keep
    }

    // 30ms 窓より短い塊でも使える RMS（声の検出用）
    static func rms(_ chunk: [Int16]) -> Double {
        guard !chunk.isEmpty else { return 0 }
        var sum = 0.0
        for v in chunk { let d = Double(v); sum += d * d }
        return (sum / Double(chunk.count)).squareRoot()
    }
}

// 手を離して録っている間、1 秒ごとに止めどきを見る
final class HandsFreeWatch {
    private var timer: Timer?

    // active が false になったら（録音が終わった・ロックに切り替えた）見るのをやめる
    func start(pressedAt: Date, lastVoiceAt: @escaping () -> Date?, active: @escaping () -> Bool,
               keyDown: @escaping () -> Bool = { false }, act: @escaping (PressGesture.Watch) -> Void) {
        stop()
        // .common に入れる: メニューを開いている間（イベント追跡のモード）も止めずに見る
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard active() else { self?.stop(); return }
            let now = Date()
            let w = PressGesture.watch(elapsed: now.timeIntervalSince(pressedAt),
                                       sinceVoice: lastVoiceAt().map { now.timeIntervalSince($0) }, keyDown: keyDown())
            guard w != .keep else { return }
            self?.stop()
            act(w)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
