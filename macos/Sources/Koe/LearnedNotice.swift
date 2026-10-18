import AppKit

// 「この 1 週間で N 語を覚えました」のお知らせ。macOS の通知は使わない（通知の許可を新しく聞かないため）。
// メニューバーのアイコンの下に小さく出し、フォーカスは奪わない（打っている文字や Enter を吸わない）。8 秒で消える。
// 出すかどうかは GlossaryCatalog.shouldNotify（週 1 回まで・使い終わって落ち着いたとき）。記録は数だけ
final class LearnedNotice: MenuBarNotice {
    static let shared = LearnedNotice()
    private static let lastShownKey = "learnedNoticeShownAt"

    // メニューに出す「今週 +N 語」の N（この 1 週間に覚えた語の数）
    static func recentCount() -> Int {
        GlossaryCatalog.learnedSince(learned(), now: Date()).count
    }

    private static func learned() -> [String: Date] {
        GlossaryCatalog.learnedDates(events: (try? String(contentsOf: Events.url, encoding: .utf8)) ?? "")
    }

    override func check() {
        guard GlossaryWindow.enabled, !isShowing else { return }
        // オンにして初めて見たときは今を「出した日」にする（オンにした直後に過去分のお知らせが出ないように。最初は 1 週間後）
        guard let lastShown = Settings.defaults.object(forKey: Self.lastShownKey) as? Date else {
            Settings.defaults.set(Date(), forKey: Self.lastShownKey)
            return
        }
        // 前に出してから 1 週間たつまでは events を読まない
        if Date().timeIntervalSince(lastShown) < GlossaryCatalog.noticeEvery { return }
        let words = GlossaryCatalog.learnedSince(Self.learned(), now: Date())
        guard GlossaryCatalog.shouldNotify(now: Date(), newCount: words.count, lastShown: lastShown,
                                           busy: busy(), lastUsed: lastUsed()) else { return }
        Settings.defaults.set(Date(), forKey: Self.lastShownKey)
        Events.log("learned_notice", ["count": words.count])
        show(GlossaryCatalog.noticeText(words))
    }

    private func show(_ text: (title: String, detail: String)) {
        present(title: text.title, detail: text.detail, detailLines: 2, width: 340,
                buttons: [button("閉じる", #selector(dismiss)), button("覚えた語を見る", #selector(openList))], hideAfter: 8)
    }

    @objc private func openList() {
        dismiss()
        GlossaryWindow.shared.show(tab: .personal, recent: true)
    }
}
