import Foundation

// 改善ループを使ってもらうための、一度きりの提案（#168）。改善ループそのものは既定オフのまま。
// 出すかどうかは shouldSuggest（純粋な関数。make test で確かめる）。オンにするのは、提案・メニュー・案内のどれかで
// 本人が押したときだけ（黙ってオンにしない）。記録は数と種類だけで、話した文は書かない。
enum ImproveSuggest {
    static let afterPastes = 30              // ループがオフのまま、これだけ貼ったら提案する
    static let snooze: TimeInterval = 14 * 86400  // 「今はしない」から次の提案まで
    static let maxShown = 2                  // 提案はこの回数まで。そのあとはメニューの項目だけ
    static let minIdle: TimeInterval = 5     // 話し終えてから少し落ち着いてから出す（録音中・文字起こし中は出さない）
    static let maxIdle: TimeInterval = 600   // しばらく使っていないときは出さない（使った直後の文脈で出す）

    struct State: Equatable {
        var pastedSinceShown = 0  // 前の提案から（最初は使い始めから）ループがオフのまま貼った回数
        var pastedTotal = 0       // ループがオフのまま貼った回数の合計（文に出す N）
        var shown = 0
        var lastShown: Date?
        var neverAgain = false    // メニューの「改善ループの提案を出さない」
    }

    // undecided: improveEnabled がまだ一度も決められていない（本人がメニューで切り替えた・配布の設定ファイルや
    // MDM で決められた、のどれでもない）。決まっていれば、オフでも提案しない
    static func shouldSuggest(_ s: State, now: Date, undecided: Bool, busy: Bool, lastUsed: Date?) -> Bool {
        guard undecided, !s.neverAgain, s.shown < maxShown, s.pastedSinceShown >= afterPastes, !busy, let lastUsed else { return false }
        let idle = now.timeIntervalSince(lastUsed)
        guard idle >= minIdle, idle <= maxIdle else { return false }
        if let last = s.lastShown, now.timeIntervalSince(last) < snooze { return false }
        return true
    }

    // ループがオフのまま 1 回貼れた
    static func pasted(_ s: State) -> State {
        var t = s
        t.pastedSinceShown += 1
        t.pastedTotal += 1
        return t
    }

    // 提案を出した（「今はしない」でも、押さずに消えても、同じく 1 回と数える）
    static func didShow(_ s: State, now: Date) -> State {
        var t = s
        t.shown += 1
        t.lastShown = now
        t.pastedSinceShown = 0
        return t
    }

    static func text(_ s: State) -> (title: String, detail: String) {
        ("ここまで \(s.pastedTotal) 回話しました",
         "改善ループを有効にすると、言い間違えられた語を覚えていきます。送る前に内容を確かめられます")
    }

    static let menuOff = "改善ループ: オフ（有効にすると使うほど賢くなります）"
    static let menuOn = "使うほど賢くする（改善ループ）"

    // MARK: 保存（UserDefaults）

    private static let keys = (sinceShown: "improveSuggestPasted", total: "improveSuggestPastedTotal",
                               shown: "improveSuggestShown", last: "improveSuggestLastShown", never: "improveSuggestNever")

    static func load(_ d: UserDefaults) -> State {
        State(pastedSinceShown: d.integer(forKey: keys.sinceShown), pastedTotal: d.integer(forKey: keys.total),
              shown: d.integer(forKey: keys.shown), lastShown: d.object(forKey: keys.last) as? Date,
              neverAgain: d.bool(forKey: keys.never))
    }

    static func save(_ s: State, _ d: UserDefaults) {
        d.set(s.pastedSinceShown, forKey: keys.sinceShown)
        d.set(s.pastedTotal, forKey: keys.total)
        d.set(s.shown, forKey: keys.shown)
        if let l = s.lastShown { d.set(l, forKey: keys.last) } else { d.removeObject(forKey: keys.last) }
        d.set(s.neverAgain, forKey: keys.never)
    }

    static func undecided(_ d: UserDefaults) -> Bool { d.object(forKey: "improveEnabled") == nil }
}
