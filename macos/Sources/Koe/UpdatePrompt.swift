import AppKit

// 了承型の更新通知（windows/core/updateprompt.go と同じ規則）。勝手に入れ替えはしない。
// 新しい版を見つけたら、使い終わって落ち着いたとき（録音中・文字起こし中でなく、最後に使ってから 30 秒以上）に 1 回だけ聞く。
// 「あとで」ならこの起動中は 24 時間出さない（次の起動ではまた聞く）。
// その版がこの OS に変更なし（CHANGELOG の節が「No changes.」）なら聞かない（メニューの「新しい版」はそのまま出る）
enum UpdatePrompt {
    static let quietAfterUse: TimeInterval = 30
    static let snooze: TimeInterval = 24 * 3600

    // 確認の画面。手で打っている最中に出ても Enter / Esc で更新が走らないように:
    // 既定（Return）は「あとで」、「今すぐ更新」はキーを持たない（クリックだけ）、Esc で押されるボタンも作らない。
    // フォーカスは奪わない（呼ぶ側は activate せず orderFrontRegardless で前に出すだけ）
    static func makeAlert(version: String, line: String?, icon: NSImage? = nil, target: AnyObject, now: Selector, later: Selector) -> NSAlert {
        let a = NSAlert()
        if let icon { a.icon = icon }
        a.messageText = "新しい版 v\(version) があります"
        a.informativeText = (line.map { $0 + "\n\n" } ?? "") + "今すぐ更新すると、Koe が数秒止まって起動し直します。あとでにすると、24 時間後か次の起動でもう一度お知らせします。"
        let l = a.addButton(withTitle: "あとで")       // 最初のボタン＝既定
        l.keyEquivalent = "\r"
        l.target = target
        l.action = later
        let n = a.addButton(withTitle: "今すぐ更新")
        n.keyEquivalent = ""
        n.keyEquivalentModifierMask = []
        n.target = target
        n.action = now
        a.window.level = .floating
        return a
    }

    // Shows the alert without a modal run loop (push-to-talk keeps working, the focus stays where it is).
    // NSAlert only lays its window out when it is run; shown with orderFrontRegardless() alone, the window
    // still holds the nib's placeholders — a "<Do not show this message again>" checkbox, a blank third
    // button, the notes in one cut-off line, no icon (#157). layout() first turns it into the real alert.
    static func present(_ a: NSAlert) {
        a.layout()
        a.window.center()
        a.window.orderFrontRegardless()
    }

    // The buttons a person can see in the alert's window (title and whether it is shown)
    static func visibleButtonTitles(_ a: NSAlert) -> [String] {
        func walk(_ v: NSView) -> [String] {
            var out: [String] = []
            if let b = v as? NSButton, !b.isHidden, !b.isHiddenOrHasHiddenAncestor, b.frame.width > 0 { out.append(b.title) }
            for s in v.subviews { out += walk(s) }
            return out
        }
        return a.window.contentView.map(walk) ?? []
    }

    static func shouldPrompt(now: Date, available: String?, busy: Bool, lastUsed: Date?, snoozedUntil: Date?, noChanges: Bool) -> Bool {
        guard available != nil, !busy, !noChanges else { return false }
        if let lastUsed, now.timeIntervalSince(lastUsed) < quietAfterUse { return false }
        if let snoozedUntil, now < snoozedUntil { return false }
        return true
    }

    // CHANGELOG.md の「## <version>」の節から、platform（"macOS" / "Windows"）の小見出しの最初の項目を 1 行にして返す。
    // 小見出しが「No changes.」なら noChanges。見つからなければ (nil, false)
    static func summary(changelog: String, version: String, platform: String, maxLength: Int = 100) -> (line: String?, noChanges: Bool) {
        var inVersion = false, inPlatform = false
        for raw in changelog.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                if inVersion { break }
                let head = String(line.dropFirst(3))
                inVersion = head == version || head.hasPrefix(version + " ")
                continue
            }
            guard inVersion else { continue }
            if line.hasPrefix("### ") {
                inPlatform = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces).lowercased() == platform.lowercased()
                continue
            }
            guard inPlatform, line.hasPrefix("- ") else { continue }
            var t = String(line.dropFirst(2))
            if t.lowercased().hasPrefix("no changes") { return (nil, true) }
            t = t.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            if t.count > maxLength { t = String(t.prefix(maxLength - 1)) + "…" }
            return (t, false)
        }
        return (nil, false)
    }
}
