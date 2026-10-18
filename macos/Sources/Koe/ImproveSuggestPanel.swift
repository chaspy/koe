import AppKit

// 改善ループの提案（#168）の小さなお知らせと、「送る内容を見る」の窓。
// お知らせは LearnedNotice と同じく、メニューバーのアイコンの下にフォーカスを奪わずに出す（モーダルにしない）。
// 出すかどうかは ImproveSuggest.shouldSuggest。押したボタンは onEnable / onPreview / onLater で呼び出し側に返す
final class ImproveSuggestPanel: MenuBarNotice {
    static let shared = ImproveSuggestPanel()
    static let visibleFor: TimeInterval = 20

    var onEnable: () -> Void = {}
    var onPreview: () -> Void = {}

    // ループがオフのまま 1 回貼れたとき（finish から）
    static func notePasted() {
        guard !Settings.improveEnabled, ImproveSuggest.undecided(Settings.defaults) else { return }
        ImproveSuggest.save(ImproveSuggest.pasted(ImproveSuggest.load(Settings.defaults)), Settings.defaults)
    }

    override func check() {
        guard !isShowing, !Settings.improveEnabled else { return }
        let s = ImproveSuggest.load(Settings.defaults)
        guard ImproveSuggest.shouldSuggest(s, now: Date(), undecided: ImproveSuggest.undecided(Settings.defaults),
                                           busy: busy(), lastUsed: lastUsed()) else { return }
        let shown = ImproveSuggest.didShow(s, now: Date())
        ImproveSuggest.save(shown, Settings.defaults)
        Events.log("improve_suggested", ["shown": shown.shown, "pasted_total": s.pastedTotal])
        show(ImproveSuggest.text(s))
    }

    private func show(_ text: (title: String, detail: String)) {
        present(title: text.title, detail: text.detail, detailLines: 3, width: 380,
                buttons: [button("今はしない", #selector(laterTapped)), button("内容を見る", #selector(previewTapped)),
                          button("有効にする", #selector(enableTapped))],
                hideAfter: Self.visibleFor,
                onTimeout: { Events.log("improve_declined", ["via": "suggestion", "reason": "timeout"]) })
    }

    @objc private func enableTapped() { dismiss(); onEnable() }
    @objc private func previewTapped() { dismiss(); onPreview() }
    @objc private func laterTapped() {
        Events.log("improve_declined", ["via": "suggestion", "reason": "later"])
        dismiss()
    }
}

// 「送る内容を見る」: 次に送る内容を、この Mac の中で組み立てて見せるだけ（何も送らない）
final class ImprovePreviewWindow: NSObject, NSWindowDelegate {
    static let shared = ImprovePreviewWindow()
    private var window: NSWindow?
    private var onEnable: (() -> Void)?

    func show(count: Int, text: String, target: String, onEnable: (() -> Void)?) {
        window?.close()
        self.onEnable = onEnable
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "改善ループで次に送る内容（まだ送っていません）"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let head = NSTextField(wrappingLabelWithString:
            "有効にすると、次の \(count) 件の文字起こしと、Claude Code のセッション記録の該当部分（送った文・返答・次の発話）を、"
            + "下の文のとおりに送ります。音声は送りません。\n送り先: \(target)\n"
            + "この窓には文字起こし（名簿を設定していれば本名も）がそのまま表示されます。画面を共有しているときは注意してください。")
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return }
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text
        let close = NSButton(title: "閉じる", target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        var views: [NSView] = [head, scroll, close]
        var enable: NSButton?
        if onEnable != nil {
            let b = NSButton(title: "有効にする", target: self, action: #selector(enableTapped))
            b.bezelStyle = .rounded
            enable = b
            views.append(b)
        }
        let box = NSView()
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; box.addSubview(v) }
        var c = [
            head.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: head.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            close.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            close.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ]
        if let enable {
            c += [enable.centerYAnchor.constraint(equalTo: close.centerYAnchor),
                  enable.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
                  close.trailingAnchor.constraint(equalTo: enable.leadingAnchor, constant: -8)]
        } else {
            c.append(close.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16))
        }
        NSLayoutConstraint.activate(c)
        w.contentView = box
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func closeTapped() { window?.close() }
    @objc private func enableTapped() {
        let f = onEnable
        window?.close()
        f?()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onEnable = nil
    }
}
