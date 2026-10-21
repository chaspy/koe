import Foundation

// 初回の案内（U-1）の判定と文言。画面（OnboardingWindow.swift）から呼ぶ。ここは AppKit に触れず、単体テストできるものだけ
// 許可 → マイクテスト → キーの練習 → 別のアプリに 1 回貼る。モデル（約 1.6GB）のダウンロード中も 1〜3 は進められる

enum OnboardingStep: Int, CaseIterable {
    case permissions, mic, key, paste
    case improve   // 使うほど賢くする（#168）。改善ループのオン・オフがまだ決まっていないときだけ、最後に足す

    var short: String {
        switch self {
        case .permissions: return "許可"
        case .mic: return "マイク"
        case .key: return "キー"
        case .paste: return "貼ってみる"
        case .improve: return "賢くする"
        }
    }

    // 押して話すキーを Koe の録音に回さず、練習に使う段（許可・マイク・キー）。最後の段だけ本物の録音で貼る
    var practisesKey: Bool { self == .permissions || self == .mic || self == .key }
}

// 流れ: 4 段（＋賢くする）で、できたら自分で次の段へ進む（マイクが聞こえた・キーの練習ができた）。「次へ」でも進める。
// 3 案（steps / auto / short）から auto に決めた（2026-10-19、docs/notes/onboarding-variants）。既定はオフ（新しい機能は既定オフで出す）
//   defaults write io.github.chaspy.koe onboarding on   （off か未設定で前の「ようこそ」）
// 案を選んでいたころの値（steps / auto / short など）が残っていても、オンとして同じ流れで開く
enum OnboardingFlow {
    static let steps: [OnboardingStep] = [.permissions, .mic, .key, .paste]

    // improve: 最後に「使うほど賢くする」を足すか（ImproveStepText.shows）
    static func steps(improve: Bool) -> [OnboardingStep] { improve ? steps + [.improve] : steps }

    static func next(after s: OnboardingStep, improve: Bool = false) -> OnboardingStep? {
        let all = steps(improve: improve)
        guard let i = all.firstIndex(of: s), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    static func previous(before s: OnboardingStep, improve: Bool = false) -> OnboardingStep? {
        let all = steps(improve: improve)
        guard let i = all.firstIndex(of: s), i > 0 else { return nil }
        return all[i - 1]
    }

    static let key = "onboarding"
    // 設定の値からオンかを決める。未設定・off・false・0・空はオフ、それ以外（on・true・古い案の名前）はオン
    static func isOn(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return !["", "off", "false", "no", "0"].contains(s.trimmingCharacters(in: .whitespaces).lowercased())
        default: return false
        }
    }
    static var enabled: Bool { isOn(UserDefaults.standard.object(forKey: key)) }
}

enum OnboardingText {
    static func keyName(_ code: Int) -> String {
        switch code {
        case 54: return "右⌘"
        case 55: return "左⌘"
        case 61: return "右⌥"
        case 58: return "左⌥"
        case 60: return "右⇧"
        case 56: return "左⇧"
        case 62: return "右⌃"
        case 59: return "左⌃"
        case 63: return "fn"
        default: return "keyCode \(code)"
        }
    }
}

// マイクテスト: 声の大きさ（0〜1）がしきい値を合わせて 0.4 秒超えたら「聞こえています」
struct MicTest {
    static let threshold: Float = 0.35
    static let needed: TimeInterval = 0.4
    static let hintAfter: TimeInterval = 6
    private(set) var heard: TimeInterval = 0
    private(set) var elapsed: TimeInterval = 0

    var passed: Bool { heard >= Self.needed - 1e-6 }
    // 6 秒たっても聞こえなければ、直し方を出す
    var showHint: Bool { !passed && elapsed >= Self.hintAfter }

    mutating func feed(level: Float, dt: TimeInterval) {
        elapsed += dt
        if level >= Self.threshold { heard += dt }
    }
}

// キーの練習の結果。録音のしきい値（Koe の minHoldSeconds・声の検出）に合わせて、話せたかを見る
enum PracticeResult: Equatable {
    case ok, tooShort, noVoice, cancelled

    static let minHold: TimeInterval = 0.8
    static let minVoiced: TimeInterval = 0.3

    static func judge(held: TimeInterval, voiced: TimeInterval, otherKey: Bool) -> PracticeResult {
        if otherKey { return .cancelled }
        if held < minHold { return .tooShort }
        return voiced >= minVoiced ? .ok : .noVoice
    }

    func message(key: String) -> String {
        switch self {
        case .ok: return "よくできました。本番では、離したところで文字が貼られます"
        case .tooShort: return "短すぎました。\(key) を押したまま、ひと言話してから離してください"
        case .noVoice: return "声が届いていません。前の「マイク」に戻って確かめてください"
        case .cancelled: return "ほかのキーを押したので取り消しました（⌘C などのショートカットはそのまま使えます）"
        }
    }
}

// モデルのダウンロードの残り時間。直近 10 秒ほどの進み方から見積もる
struct DownloadETA {
    private(set) var samples: [(t: TimeInterval, p: Double)] = []
    static let window: TimeInterval = 10

    mutating func add(progress: Double, at t: TimeInterval) {
        samples.append((t, progress))
        samples.removeAll { t - $0.t > Self.window }
    }

    // 残りの秒数。見積もれなければ nil
    func remaining() -> TimeInterval? {
        guard let a = samples.first, let b = samples.last, b.t - a.t >= 2, b.p > a.p else { return nil }
        let rate = (b.p - a.p) / (b.t - a.t)
        return max(0, (1 - b.p) / rate)
    }

    static func text(_ seconds: TimeInterval?) -> String {
        guard let s = seconds else { return "" }
        if s < 45 { return "まもなく終わります" }
        let m = Int((s / 60).rounded())
        return m <= 1 ? "あと 1 分ほど" : "あと約 \(m) 分"
    }

    // 下に出す 1 行。progress は 0〜1（nil = ダウンロードしていない）
    static func line(progress: Double?, ready: Bool, eta: TimeInterval?) -> String {
        if let p = progress {
            let rest = text(eta)
            return String(format: "音声認識のモデル（約 1.6GB）をダウンロード中… %.0f%%", p * 100) + (rest.isEmpty ? "" : "・\(rest)") + "。その間に練習できます"
        }
        return ready ? "音声認識の準備ができました" : "音声認識のモデルを読み込み中…"
    }
}

// 最後の段: 別のアプリに貼れたか。Koe の画面に向かって話した（貼り先が Koe）ときは、やり直しを促す
enum PasteCheck: Equatable {
    case success, intoKoe, notPasted

    static func judge(pasted: Bool, pasteApp: String?, koe: String) -> PasteCheck {
        guard pasted else { return .notPasted }
        return pasteApp == koe ? .intoKoe : .success
    }
}

// 貼る段の練習用の書類（一時フォルダの「Koe の練習.txt」）。話した文を手元に残さないよう、開くたびに空にし、
// 案内を閉じたときは消す（テキストエディットは開いている書類を自動で保存するので、貼った文がファイルに書かれる）。
// テキストエディットに「保存しない新しい書類」を開かせるには AppleScript（オートメーションの許可）が要るので、使わない
enum PracticeFile {
    static func url(in dir: URL = FileManager.default.temporaryDirectory) -> URL {
        dir.appendingPathComponent("Koe の練習.txt")
    }

    // 開く前: 空のファイルにする（無ければ作る）
    static func prepare(_ url: URL) {
        try? Data().write(to: url, options: .atomic)
    }

    // 閉じたとき: 消す（無ければ何もしない）
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
