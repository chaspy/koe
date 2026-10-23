import AppKit
import AVFoundation
import ApplicationServices

// 許可の案内（U-2）。アクセシビリティ・マイクの許可が無いとき、システム設定の窓の横に小さな案内を浮かべる。
// - 案内は前に出すだけでフォーカスを奪わない（システム設定でスイッチを押す手を止めない）
// - システム設定の窓を動かすと付いていく。システム設定が開いていなければ画面の右上（メニューバーの Koe の下あたり）
// - 許可されたら自動で「オンになりました」と出して閉じる。もう一方の許可も無ければ続けてそちらを案内する
// - 一度は許可されていたのに外れた（更新で署名が変わった等）ときは、一覧で「オン」に見えても効いていないので、
//   「−」で消して「+」で追加し直す手順を出す。許可の履歴がない場合も条件付きで案内する。
// 送るもの・書くものは増やさない。events には許可の種類ときっかけだけを書く
enum Permission: String {
    case accessibility, microphone

    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(self == .accessibility ? "Privacy_Accessibility" : "Privacy_Microphone")")!
    }
}

enum PermissionCheck {
    // マイクは「まだ聞いていない」ならシステムの確認が出るので、案内は「断られた・制限された」ときだけ
    static func micMissing(_ s: AVAuthorizationStatus) -> Bool { s == .denied || s == .restricted }

    static var micDenied: Bool { micMissing(AVCaptureDevice.authorizationStatus(for: .audio)) }

    // 案内する順: キーと貼り付けに要るアクセシビリティが先（無いと黙って貼れない）
    static func missing(ax: Bool, mic: AVAuthorizationStatus) -> [Permission] {
        var m: [Permission] = []
        if !ax { m.append(.accessibility) }
        if micMissing(mic) { m.append(.microphone) }
        return m
    }

    static func missingNow() -> [Permission] {
        missing(ax: AXIsProcessTrusted(), mic: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    // アクセシビリティの修復案内は設定によらず有効。マイクの追加ガイドだけ opt-in。
    static func guidedMissing(ax: Bool, mic: AVAuthorizationStatus, extendedGuide: Bool) -> [Permission] {
        missing(ax: ax, mic: mic).filter { $0 == .accessibility || extendedGuide }
    }

    // 自動で出す案内は、本人が閉じてから 1 分は出し直さない（貼り付けに失敗するたびに出ると邪魔）。メニューから開いたときはいつでも出す
    static let quietAfterClose: TimeInterval = 60
    static func shouldShow(manual: Bool, lastClosed: Date?, now: Date) -> Bool {
        if manual { return true }
        guard let lastClosed else { return true }
        return now.timeIntervalSince(lastClosed) >= quietAfterClose
    }
}

// 案内の文言（テストで中身を確かめる）
enum PermissionText {
    static let readd = "一覧ですでに Koe がオンなら、Koe を選んで「−」で削除し、「+」で Koe を追加し直してオンにしてください。"
    static let accessibilityMenu = "アクセシビリティ未許可（すでにオンなら Koe を「−」で削除→「+」で再追加）"

    static func title(_ p: Permission, stale: Bool) -> String {
        switch p {
        case .accessibility: return stale ? "Koe の「アクセシビリティ」の許可が外れています" : "Koe に「アクセシビリティ」の許可が必要です"
        case .microphone: return "Koe に「マイク」の許可が必要です"
        }
    }

    static func reason(_ p: Permission, stale: Bool) -> String {
        switch p {
        case .accessibility:
            return stale
                ? "更新のあとなどに、許可が外れることがあります。一覧でオンに見えていても効いていません。"
                : "キーを押したことに気づき、話した文を貼り付けるために使います。"
        case .microphone:
            return "話した声を文字にするために使います。音声は Mac の外に送りません。"
        }
    }

    static func steps(_ p: Permission, stale: Bool) -> [String] {
        switch p {
        case .accessibility where stale:
            return [readd, "一覧に Koe が無いときも「+」から追加できます。右のアイコンのドラッグでも追加できます。"]
        case .accessibility:
            return ["開いた一覧で、Koe のスイッチをオンにする",
                    "一覧に Koe が無いときは「+」で追加する（右のアイコンのドラッグでも追加できます）", readd]
        case .microphone:
            return ["開いた一覧で、Koe のスイッチをオンにする",
                    "オンにしても声が入らないときは、下の「Koe を再起動」を押す"]
        }
    }

    static let waiting = "まだ許可を確認できません。許可されると、この案内は自動で閉じます"
    static let granted = "オンになりました"
    static let stillOff = "まだ許可を確認できません。上の手順をもう一度お試しください"
}

// 案内を置く場所（Cocoa の座標。左下が原点）。
// システム設定の窓の右 → 左 → 窓の中の右下、の順に、画面に収まるところへ置く。窓が無ければ画面の右上
enum PermissionPlacement {
    static let gap: CGFloat = 12
    static let margin: CGFloat = 16

    static func origin(panel: CGSize, beside win: CGRect?, visible: CGRect) -> CGPoint {
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, visible.minY + margin), visible.maxY - panel.height - margin) }
        guard let win else {
            return CGPoint(x: visible.maxX - panel.width - margin, y: visible.maxY - panel.height - margin)
        }
        let top = clampY(win.maxY - panel.height)
        if win.maxX + gap + panel.width <= visible.maxX { return CGPoint(x: win.maxX + gap, y: top) }
        if win.minX - gap - panel.width >= visible.minX { return CGPoint(x: win.minX - gap - panel.width, y: top) }
        return CGPoint(x: max(visible.minX + margin, win.maxX - panel.width - margin), y: clampY(win.minY + margin))
    }

    // CGWindowList の座標（主画面の左上が原点・下向き）を Cocoa の座標に直す
    static func cocoaRect(_ cg: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    // 画面に出ているシステム設定の窓（いちばん大きいもの）。窓の名前は読まない（画面収録の許可が要り、中身にも触れない）
    static func systemSettingsWindow() -> CGRect? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").map { $0.processIdentifier })
        guard !pids.isEmpty, let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let rects = list.compactMap { w -> CGRect? in
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.width > 200, r.height > 200 else { return nil }
            return r
        }
        guard let big = rects.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        return cocoaRect(big, primaryHeight: primary.frame.height)
    }
}

// ドラッグできる Koe のアイコン（システム設定のアクセシビリティの一覧へ落とすと Koe が加わる）
final class AppIconDragView: NSView, NSDraggingSource {
    private let icon: NSImage
    init(size: CGFloat) {
        icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: size, height: size)
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        toolTip = "このアイコンをシステム設定の一覧へドラッグ"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) { icon.draw(in: bounds) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}

// フォーカスを奪わずにボタンを押せる小さな窓
final class GuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PermissionGuide: NSObject, NSWindowDelegate {
    // マイクの追加ガイドは既定オフ。アクセシビリティの修復案内は常時有効。
    // defaults write io.github.chaspy.koe permissionGuide -bool true でオン
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "permissionGuide") }

    // 許可されたとき（キー監視の張り直し・マイクの開き直しは呼ぶ側で）
    var onGranted: ((Permission) -> Void)?
    // events に残す（種類ときっかけだけ）
    var log: (String, [String: Any]) -> Void = { _, _ in }
    // 今その許可が足りないか（見た目の確認では差し替える）
    var isMissing: (Permission) -> Bool = { PermissionCheck.missingNow().contains($0) }

    private var panel: GuidePanel?
    private var current: Permission?
    private var stale = false
    private var timer: Timer?
    private var lastClosed: Date?
    private var statusLabel: NSTextField?
    private var closing = false

    var isVisible: Bool { panel?.isVisible == true }

    // 一度でも許可されていたか。外れたときに「消して入れ直す」手順を出すために覚えておく
    private static let trustedKey = "accessibilityTrustedOnce"
    static func noteTrusted() {
        if AXIsProcessTrusted() { UserDefaults.standard.set(true, forKey: trustedKey) }
    }
    static var trustedBefore: Bool { UserDefaults.standard.bool(forKey: trustedKey) }

    // 足りない許可があれば案内する。manual はメニューから開いたとき。戻り値は案内を出したか
    @discardableResult
    func showIfNeeded(reason: String, manual: Bool = false, only: Permission? = nil) -> Bool {
        Self.noteTrusted()
        let missing = PermissionCheck.guidedMissing(ax: AXIsProcessTrusted(),
                                                    mic: AVCaptureDevice.authorizationStatus(for: .audio),
                                                    extendedGuide: Self.enabled).filter { only == nil || $0 == only }
        guard let p = missing.first else { return false }
        // 別の許可を案内している最中なら差し替えない（そちらが済んだら続けて案内する）
        if isVisible && current != nil {
            if current == p { panel?.orderFrontRegardless() }
            return true
        }
        guard PermissionCheck.shouldShow(manual: manual, lastClosed: lastClosed, now: Date()) else { return false }
        show(p, reason: reason)
        return true
    }

    func show(_ p: Permission, reason: String, stale forced: Bool? = nil) {
        current = p
        stale = forced ?? (p == .accessibility && Self.trustedBefore)
        closing = false
        log("permission_guide", ["permission": p.rawValue, "reason": reason, "stale": stale])
        build(p)
        reposition()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        // 0.5 秒ごとに、許可されたか・システム設定の窓がどこにあるかを見る
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        current = nil
    }

    private func tick() {
        guard let p = current, !closing else { return }
        reposition()
        if !isMissing(p) { granted(p) }
    }

    private func granted(_ p: Permission) {
        closing = true
        Self.noteTrusted()
        log("permission_granted", ["permission": p.rawValue, "stale": stale])
        setStatus("✓ " + PermissionText.granted, color: .systemGreen)
        onGranted?(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.current == p else { return }
            self.close()
            // もう一方も足りなければ続けて案内する
            self.showIfNeeded(reason: "after_\(p.rawValue)", manual: true)
        }
    }

    private func reposition() {
        guard let panel else { return }
        let win = PermissionPlacement.systemSettingsWindow()
        let screen = win.flatMap { w in NSScreen.screens.max { $0.frame.intersection(w).area < $1.frame.intersection(w).area } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let o = PermissionPlacement.origin(panel: panel.frame.size, beside: win, visible: visible)
        if panel.frame.origin != o { panel.setFrameOrigin(o) }
    }

    private func setStatus(_ text: String, color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
    }

    // MARK: 窓

    private func build(_ p: Permission) {
        let width: CGFloat = 380
        let pnl = panel ?? {
            let w = GuidePanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
                               styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                               backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.level = .floating
            w.hidesOnDeactivate = false
            w.isReleasedWhenClosed = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.becomesKeyOnlyIfNeeded = true
            w.delegate = self
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            return w
        }()
        panel = pnl

        let title = NSTextField(wrappingLabelWithString: PermissionText.title(p, stale: stale))
        title.font = .boldSystemFont(ofSize: 15)
        let reason = NSTextField(wrappingLabelWithString: PermissionText.reason(p, stale: stale))
        reason.font = .systemFont(ofSize: 12)
        reason.textColor = .secondaryLabelColor

        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 8
        for (i, s) in PermissionText.steps(p, stale: stale).enumerated() {
            let n = NSTextField(labelWithString: ["①", "②", "③"][min(i, 2)])
            n.font = .boldSystemFont(ofSize: 14)
            n.textColor = .controlAccentColor
            let t = NSTextField(wrappingLabelWithString: s)
            t.font = .systemFont(ofSize: 13)
            t.preferredMaxLayoutWidth = p == .accessibility ? width - 130 : width - 70
            let row = NSStackView(views: [n, t])
            row.alignment = .firstBaseline
            row.spacing = 6
            steps.addArrangedSubview(row)
        }

        var middle: [NSView] = [steps]
        if p == .accessibility {
            let drag = AppIconDragView(size: 56)
            let cap = NSTextField(labelWithString: "Koe（ドラッグ）")
            cap.font = .systemFont(ofSize: 10)
            cap.textColor = .secondaryLabelColor
            let col = NSStackView(views: [drag, cap])
            col.orientation = .vertical
            col.spacing = 2
            middle.append(col)
        }
        let body = NSStackView(views: middle)
        body.alignment = .centerY
        body.spacing = 12

        let status = NSTextField(wrappingLabelWithString: "● " + PermissionText.waiting)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .systemOrange
        statusLabel = status

        let open = NSButton(title: "システム設定を開く", target: self, action: #selector(openSettings))
        // 青い既定のボタンにする。案内はキーを取らないので、他のアプリで打っている Enter では押されない（押されても設定が開くだけ）
        open.keyEquivalent = "\r"
        let recheck = NSButton(title: "もう一度確かめる", target: self, action: #selector(recheck))
        let restart = NSButton(title: "Koe を再起動", target: self, action: #selector(restartKoe))
        let buttons = NSStackView(views: [open, recheck, restart])
        buttons.spacing = 8

        let stack = NSStackView(views: [title, reason, body, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [title, reason, status] {
            v.preferredMaxLayoutWidth = width - 36
        }

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: width),
        ])
        pnl.contentView = bg
        pnl.setContentSize(bg.fittingSize)
    }

    @objc private func openSettings() {
        guard let p = current else { return }
        log("permission_guide_open", ["permission": p.rawValue])
        // アクセシビリティは、一覧に Koe を載せるためにシステムの確認も出す（載っていればスイッチを押すだけになる）
        if p == .accessibility && !stale {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        NSWorkspace.shared.open(p.settingsURL)
    }

    @objc private func recheck() {
        guard let p = current else { return }
        if isMissing(p) {
            setStatus("● " + PermissionText.stillOff, color: .systemOrange)
            NSSound.beep()
        } else {
            granted(p)
        }
    }

    @objc private func restartKoe() {
        log("permission_guide_restart", ["permission": current?.rawValue ?? ""])
        Self.relaunch()
    }

    // Koe が終わるのを待ってから開き直す（終わるのは録音・文字起こしが済んでから）
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The pid and the bundle path are passed as arguments, not put into the script
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.3; done; open \"$2\"", "sh",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if !closing, let p = current { log("permission_guide_closed", ["permission": p.rawValue]) }
        lastClosed = Date()
        timer?.invalidate()
        timer = nil
        current = nil
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
