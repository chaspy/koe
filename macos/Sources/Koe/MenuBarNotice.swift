import AppKit

// メニューバーのアイコンの下に小さく出すお知らせの共通部分（LearnedNotice・ImproveSuggestPanel）。
// macOS の通知は使わない（通知の許可を新しく聞かないため）。フォーカスは奪わず（打っている文字や Enter を吸わない）、
// モーダルにもしない。1 分ごとに check() を呼ぶので、出すかどうかは継承した側が決める
class MenuBarNotice: NSObject {
    private(set) weak var statusItem: NSStatusItem?
    private(set) var busy: () -> Bool = { false }
    private(set) var lastUsed: () -> Date? = { nil }
    private var timer: Timer?
    private var panel: NSPanel?
    private var hide: DispatchWorkItem?

    var isShowing: Bool { panel != nil }

    func start(statusItem: NSStatusItem, busy: @escaping () -> Bool, lastUsed: @escaping () -> Date?) {
        self.statusItem = statusItem
        self.busy = busy
        self.lastUsed = lastUsed
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
    }

    // 継承した側で、出すかどうかを決めて present を呼ぶ
    func check() {}

    func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.keyEquivalent = ""
        return b
    }

    // buttons は左から右の順。いちばん右のボタンを右下に置き、残りはその左に並べる。
    // hideAfter 秒で消える（そのとき onTimeout を呼ぶ）
    func present(title: String, detail: String, detailLines: Int, width w: CGFloat, buttons: [NSButton],
                 hideAfter: TimeInterval, onTimeout: (() -> Void)? = nil) {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: 100), styleMask: [.nonactivatingPanel, .borderless],
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
        let titleField = NSTextField(labelWithString: "Koe: " + title)
        titleField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.textColor = .secondaryLabelColor
        detailField.maximumNumberOfLines = detailLines
        for v in [titleField, detailField] + buttons as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        var c = [
            titleField.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -14),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 4),
            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
        ]
        if let last = buttons.last {
            c += [last.topAnchor.constraint(equalTo: detailField.bottomAnchor, constant: 8),
                  last.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
                  last.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -10)]
            for (b, right) in zip(buttons.dropLast(), buttons.dropFirst()) {
                c += [b.centerYAnchor.constraint(equalTo: last.centerYAnchor),
                      b.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -6)]
            }
        }
        NSLayoutConstraint.activate(c)
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
        let item = DispatchWorkItem { [weak self] in
            onTimeout?()
            self?.dismiss()
        }
        hide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hideAfter, execute: item)
    }

    @objc func dismiss() {
        hide?.cancel()
        hide = nil
        panel?.orderOut(nil)
        panel = nil
    }
}
