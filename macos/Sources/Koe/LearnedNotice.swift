import AppKit

// 「この 1 週間で N 語を覚えました」のお知らせ。macOS の通知は使わない（通知の許可を新しく聞かないため）。
// メニューバーのアイコンの下に小さく出し、フォーカスは奪わない（打っている文字や Enter を吸わない）。8 秒で消える。
// 出すかどうかは GlossaryCatalog.shouldNotify（週 1 回まで・使い終わって落ち着いたとき）。記録は数だけ
final class LearnedNotice: NSObject {
    static let shared = LearnedNotice()
    private static let lastShownKey = "learnedNoticeShownAt"

    private var timer: Timer?
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?
    private var busy: () -> Bool = { false }
    private var lastUsed: () -> Date? = { nil }
    private weak var statusItem: NSStatusItem?

    func start(statusItem: NSStatusItem, busy: @escaping () -> Bool, lastUsed: @escaping () -> Date?) {
        self.statusItem = statusItem
        self.busy = busy
        self.lastUsed = lastUsed
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
    }

    // メニューに出す「今週 +N 語」の N（この 1 週間に覚えた語の数）
    static func recentCount() -> Int {
        GlossaryCatalog.learnedSince(learned(), now: Date()).count
    }

    private static func learned() -> [String: Date] {
        GlossaryCatalog.learnedDates(events: (try? String(contentsOf: Events.url, encoding: .utf8)) ?? "")
    }

    private func check() {
        guard GlossaryWindow.enabled, panel == nil else { return }
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
        let w: CGFloat = 340
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: 96), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient]

        let box = NSVisualEffectView()
        box.material = .popover
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        let title = NSTextField(labelWithString: "Koe: " + text.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let detail = NSTextField(wrappingLabelWithString: text.detail)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let open = NSButton(title: "覚えた語を見る", target: self, action: #selector(openList))
        open.bezelStyle = .rounded
        open.keyEquivalent = ""
        let close = NSButton(title: "閉じる", target: self, action: #selector(dismiss))
        close.bezelStyle = .rounded
        for v in [title, detail, open, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            open.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 8),
            open.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            open.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: open.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -6),
        ])
        p.contentView = box
        box.layoutSubtreeIfNeeded()
        let h = box.fittingSize.height
        // メニューバーのアイコンの真下（右端からはみ出さないように）。アイコンの位置が取れなければ画面の右上
        var origin = NSPoint.zero
        if let b = statusItem?.button, let bw = b.window {
            let r = bw.convertToScreen(b.convert(b.bounds, to: nil))
            let screen = bw.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            origin = NSPoint(x: min(r.midX - w / 2, screen.maxX - w - 8), y: r.minY - h - 6)
        } else if let s = NSScreen.main?.visibleFrame {
            origin = NSPoint(x: s.maxX - w - 12, y: s.maxY - h - 8)
        }
        p.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        panel = p
        p.orderFrontRegardless()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
    }

    @objc private func openList() {
        dismiss()
        GlossaryWindow.shared.show(tab: .personal, recent: true)
    }

    @objc private func dismiss() {
        hide?.cancel()
        hide = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
