import AppKit
import AVFoundation
import ApplicationServices

// 初回の案内の画面（U-1）。許可 → マイクテスト → キーの練習 → 別のアプリに 1 回貼る。
// - 初めて起動したときに開く。メニューの「はじめての案内を開く…」でいつでも開き直せる
// - モデル（約 1.6GB）のダウンロード中も、許可・マイク・キーの練習は進められる（下に進み具合と残り時間）
// - 許可は PermissionGuide（U-2）、声の大きさは AudioLevel・LevelBarsView（U-8）を使い回す
// - 練習の段では、押して話すキーを Koe の録音に回さない（この画面の上で押したときだけ）。最後の段だけ本物の録音で貼る
// events には段・結果の種類だけを書く（話した中身・貼った文は書かない）
final class OnboardingWindow: NSObject, NSWindowDelegate {
    var log: (String, [String: Any]) -> Void = { _, _ in }
    var hotkeyCode: () -> Int = { 54 }
    var setHotkey: (Int) -> Void = { _ in }
    var inputLevel: () -> Float = { 0 }          // マイクの今の声の大きさ（RMS）
    var setWarm: (Bool) -> Void = { _ in }       // マイクを開いておく（練習の間だけ）
    var isWarm: () -> Bool = { true }
    var micNames: () -> [String] = { [] }
    var currentMic: () -> String? = { nil }       // nil = 自動
    var activeMicName: () -> String = { "" }
    var selectMic: (String?) -> Void = { _ in }
    var openPermission: (Permission) -> Void = { _ in }
    // 使うほど賢くする（#168）。オンにする・送る内容を見るは、メニュー・提案と同じ経路（同意の確認つき）
    var improveUndecided: () -> Bool = { false }
    var improveEnabled: () -> Bool = { false }
    var improveReadiness: (@escaping (ImproveReadiness) -> Void) -> Void = { _ in }
    var enableImprove: () -> Void = {}
    var previewImprove: (@escaping () -> Void) -> Void = { _ in }   // 送る発話が無いときに呼ばれる
    var onClose: () -> Void = {}

    private var window: NSWindow?
    private(set) var step: OnboardingStep = .permissions
    private var timer: Timer?
    private var ticks = 0
    private var restoreWarm: Bool?

    // モデル
    private var modelProgress: Double?
    private var modelReady = false
    private var eta = DownloadETA()

    // 段ごとの状態
    private var micTest = MicTest()
    private var micPassed = false
    private var keyDownAt: Date?
    private var otherKeyWhileHeld = false
    private var voiced: TimeInterval = 0
    private var practiced = false
    private var pasted = false
    private var smoothed: Float = 0

    // 画面の部品（段ごとに作り直す）
    private let content = NSView()
    private let stepsLabel = NSTextField(labelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "")
    private let modelBar = NSProgressIndicator()
    private let nextButton = NSButton()
    private let backButton = NSButton()
    private var permRows: [Permission: NSView] = [:]
    private var meter: MeterView?
    private var statusLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var keycap: KeycapView?
    private var pillBars: LevelBarsView?
    private var pillLabel: NSTextField?
    private var withImprove = false
    private var improveButtons: NSStackView?
    private var improveEnableButton: NSButton?
    private let laterButton = NSButton()

    var isVisible: Bool { window?.isVisible == true }

    // 練習の段で、この画面の上で押したキーは Koe の録音に回さない
    var interceptsHotkey: Bool {
        guard let w = window, w.isVisible, w.isKeyWindow else { return false }
        return step.practisesKey
    }

    func show(reason: String) {
        if isVisible { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        log("onboarding_opened", ["reason": reason])
        if window == nil { build() }
        practiced = false; pasted = false; micPassed = false; permissionsWereMissing = false
        withImprove = ImproveStepText.shows(undecided: improveUndecided(), enabled: improveEnabled())
        go(.expectations)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startTimer()
    }

    // render() から呼ぶ。ダウンロードの進み具合と、whisper-server の準備
    func update(modelProgress p: Double?, ready: Bool) {
        if let p { eta.add(progress: p, at: Date().timeIntervalSinceReferenceDate) }
        guard p != modelProgress || ready != modelReady else { return }
        modelProgress = p
        modelReady = ready
        guard isVisible else { return }
        refreshModel()
        if step == .paste { refreshPasteStatus() }
    }

    // 押して話すキー・ほかのキーの知らせ（interceptsHotkey のときだけ呼ばれる）
    func hotkey(down: Bool) {
        guard step == .key else { return }
        if down {
            keyDownAt = Date()
            voiced = 0
            otherKeyWhileHeld = false
            keycap?.pressed = true
            pillLabel?.stringValue = "録音中"
            statusLabel?.stringValue = "話してください… 話し終えたら離します"
            statusLabel?.textColor = .secondaryLabelColor
        } else if let at = keyDownAt {
            keyDownAt = nil
            keycap?.pressed = false
            pillLabel?.stringValue = "（待機中）"
            let r = PracticeResult.judge(held: Date().timeIntervalSince(at), voiced: voiced, otherKey: otherKeyWhileHeld)
            log("onboarding_practice", ["result": "\(r)"])
            statusLabel?.stringValue = (r == .ok ? "✓ " : "") + r.message(key: keyName)
            statusLabel?.textColor = r == .ok ? .systemGreen : .systemOrange
            if r == .ok {
                practiced = true
                refreshButtons()
                advanceSoon(from: .key, after: 1.2)
            }
        }
    }

    func otherKey() {
        if keyDownAt != nil { otherKeyWhileHeld = true }
    }

    // 貼り終えた（または貼れなかった）発話。最後の段だけ見る
    func notePaste(pasted ok: Bool, pasteApp: String?) {
        guard isVisible, step == .paste, !pasted else { return }
        switch PasteCheck.judge(pasted: ok, pasteApp: pasteApp, koe: Bundle.main.bundleIdentifier ?? "") {
        case .success:
            pasted = true
            log("onboarding_pasted", [:])
            refreshPasteStatus()
            refreshButtons()
            // 貼った先のアプリの上に、この画面を見せる（フォーカスは移さない）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.window?.orderFrontRegardless() }
        case .intoKoe:
            setStatus("Koe のこの画面ではなく、テキストエディットなどの入力欄をクリックしてから話してください", .systemOrange)
        case .notPasted:
            break
        }
    }

    private var keyName: String { OnboardingText.keyName(hotkeyCode()) }

    private var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    // MARK: 段の移り変わり

    var windowNumber: Int { window?.windowNumber ?? 0 }

    func go(_ s: OnboardingStep) {
        step = s
        if s != .expectations, restoreWarm == nil { restoreWarm = isWarm(); if !isWarm() { setWarm(true) } }
        log("onboarding_step", ["step": "\(s)"])
        keyDownAt = nil
        content.subviews.forEach { $0.removeFromSuperview() }
        permRows = [:]
        meter = nil; statusLabel = nil; hintLabel = nil; keycap = nil; pillBars = nil; pillLabel = nil
        improveButtons = nil; improveEnableButton = nil
        let v: NSView
        switch s {
        case .expectations: v = expectationsView()
        case .permissions: v = permissionsView()
        case .mic: micTest = MicTest(); micPassed = false; v = micView()
        case .key: v = keyView()
        case .paste: v = pasteView()
        case .improve: v = improveView()
        }
        v.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            v.topAnchor.constraint(equalTo: content.topAnchor),
            v.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        refreshSteps()
        refreshButtons()
        refreshModel()
        if s == .permissions { refreshPermissions() }
        if s == .paste { refreshPasteStatus() }
    }

    @objc private func nextStep() {
        if let n = OnboardingFlow.next(after: step, improve: withImprove) { go(n) } else { finish() }
    }

    @objc private func previousStep() {
        if let p = OnboardingFlow.previous(before: step, improve: withImprove) { go(p) }
    }

    // 少し ✓ を見せてから、まだその段にいれば次へ
    private func advanceSoon(from s: OnboardingStep, after seconds: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.isVisible, self.step == s, let n = OnboardingFlow.next(after: s, improve: self.withImprove) { self.go(n) }
        }
    }

    @objc private func later() {
        log("onboarding_later", ["step": "\(step)"])
        window?.close()
    }

    private func finish() {
        if step == .improve && !improveEnabled() { log("improve_declined", ["via": "onboarding", "reason": "later"]) }
        log("onboarding_done", ["pasted": pasted])
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if let w = restoreWarm, !w { setWarm(false) }
        restoreWarm = nil
        PracticeFile.remove(PracticeFile.url())   // 練習で貼った文をファイルに残さない
        onClose()
    }

    // MARK: 時計（30 コマ/秒）

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        ticks += 1
        let dt = 1.0 / 30
        let level = AudioLevel.normalized(rms: inputLevel())
        smoothed = AudioLevel.smooth(smoothed, level)
        switch step {
        case .permissions:
            if ticks % 15 == 0 { refreshPermissions() }
        case .mic:
            meter?.level = smoothed
            meter?.passed = micPassed
            micTest.feed(level: level, dt: dt)
            if micTest.passed && !micPassed {
                micPassed = true
                log("onboarding_mic_ok", [:])
                setStatus("✓ 聞こえています", .systemGreen)
                hintLabel?.isHidden = true
                refreshButtons()
                advanceSoon(from: .mic, after: 1.0)
            } else if micTest.showHint && hintLabel?.isHidden == true {
                hintLabel?.isHidden = false
                refreshButtons()
            }
        case .key:
            if keyDownAt != nil {
                if level >= AudioLevel.normalized(rms: 330) { voiced += dt }
                pillBars?.heights = HUDLayout.barHeights(.recording(since: Date(), locked: false, app: nil), level: smoothed, t: Date().timeIntervalSinceReferenceDate)
            } else {
                pillBars?.heights = HUDLayout.barHeights(.recording(since: Date(), locked: false, app: nil), level: 0, t: 0)
            }
        case .expectations, .paste, .improve:
            break
        }
    }

    // MARK: 表示の更新

    private func refreshSteps() {
        let s = NSMutableAttributedString()
        for (i, st) in OnboardingFlow.steps(improve: withImprove).enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "   ›   ", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])) }
            let done = st.rawValue < step.rawValue
            let text = (done ? "✓ " : "\(i + 1). ") + st.short
            let color: NSColor = st == step ? .controlAccentColor : done ? .systemGreen : .secondaryLabelColor
            let font: NSFont = st == step ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
            s.append(NSAttributedString(string: text, attributes: [.foregroundColor: color, .font: font]))
        }
        stepsLabel.attributedStringValue = s
    }

    private func refreshButtons() {
        backButton.isHidden = OnboardingFlow.previous(before: step, improve: withImprove) == nil
        laterButton.isHidden = step == .improve   // この段では右下の「あとで」が同じ役目
        switch step {
        case .expectations:
            nextButton.title = "はじめる"
            nextButton.isEnabled = true
        case .permissions:
            nextButton.title = "次へ"
            nextButton.isEnabled = PermissionCheck.missingNow().isEmpty && micAuthorized
        case .mic:
            nextButton.title = micPassed ? "次へ" : (micTest.showHint ? "このまま進む" : "次へ")
            nextButton.isEnabled = micPassed || micTest.showHint
        case .key:
            nextButton.title = practiced ? "次へ" : "飛ばす"
            nextButton.isEnabled = true
        case .paste:
            nextButton.title = OnboardingFlow.next(after: .paste, improve: withImprove) == nil ? "完了" : "次へ"
            nextButton.isEnabled = true
        case .improve:
            nextButton.title = improveEnabled() ? "完了" : "あとで"
            nextButton.isEnabled = true
        }
        nextButton.keyEquivalent = nextButton.isEnabled && (step != .key || practiced) && (step != .paste || pasted)
            && (step != .improve || improveEnabled()) ? "\r" : ""
    }

    private func refreshModel() {
        let rest = modelProgress.flatMap { _ in eta.remaining() }
        modelLabel.stringValue = DownloadETA.line(progress: modelProgress, ready: modelReady, eta: rest)
        modelLabel.textColor = modelReady && modelProgress == nil ? .systemGreen : .secondaryLabelColor
        modelBar.isHidden = modelProgress == nil
        modelBar.doubleValue = (modelProgress ?? 0) * 100
    }

    private var permissionsWereMissing = false
    private func refreshPermissions() {
        let micOK = micAuthorized
        let axOK = AXIsProcessTrusted()
        setRow(.microphone, ok: micOK)
        setRow(.accessibility, ok: axOK)
        let all = micOK && axOK
        if !all { permissionsWereMissing = true }
        let wasEnabled = nextButton.isEnabled
        refreshButtons()
        // 揃ったら少し見せてから次へ進む
        if all && !wasEnabled && permissionsWereMissing {
            log("onboarding_permissions_ok", [:])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { if self.step == .permissions, let n = OnboardingFlow.next(after: .permissions) { self.go(n) } }
        }
    }

    private func setRow(_ p: Permission, ok: Bool) {
        guard let row = permRows[p] else { return }
        (row.viewWithTag(1) as? NSButton)?.isHidden = ok
        (row.viewWithTag(2) as? NSTextField)?.isHidden = !ok
    }

    private func refreshPasteStatus() {
        guard step == .paste else { return }
        if pasted {
            setStatus("✓ 貼れました！ これで準備は完了です", .systemGreen)
            hintLabel?.isHidden = false
        } else if !modelReady || modelProgress != nil {
            setStatus("⏳ 音声認識の準備を待っています（下の進み具合）。準備ができたら試せます", .secondaryLabelColor)
        } else {
            setStatus("● 待っています… 入力欄をクリックしてから \(keyName) を押しながら話してください", .secondaryLabelColor)
        }
    }

    private func setStatus(_ text: String, _ color: NSColor) {
        statusLabel?.stringValue = text
        statusLabel?.textColor = color
    }

    // MARK: 段の画面

    private func title(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 20, weight: .semibold)
        return t
    }

    private func body(_ s: String, size: CGFloat = 13, color: NSColor = .labelColor) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: size)
        t.textColor = color
        t.preferredMaxLayoutWidth = 520
        return t
    }

    private func status(_ s: String) -> NSTextField {
        let t = body(s, color: .secondaryLabelColor)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel = t
        return t
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 14) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func expectationsView() -> NSView {
        vstack([
            title(OnboardingFlow.title),
            body(OnboardingFlow.introduction),
            body("合成例（説明用に作った会話）", size: 11, color: .secondaryLabelColor),
            body("Koe の入力：このプロリクのテストが落ちてるので、原因を見て直して", size: 14),
            body("AI の返答：プルリクエストのテストが落ちている件ですね。ログを確認します…", size: 14),
            body("「プロリク」と化けても、AI は「プルリク」と受け取っています", size: 12, color: .secondaryLabelColor),
            body(OnboardingFlow.finalText, size: 12, color: .secondaryLabelColor),
        ], spacing: 12)
    }

    private func permissionsView() -> NSView {
        func row(_ p: Permission, symbol: String, name: String, why: String) -> NSView {
            let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
            icon.contentTintColor = .controlAccentColor
            icon.widthAnchor.constraint(equalToConstant: 32).isActive = true
            let n = NSTextField(labelWithString: name)
            n.font = .boldSystemFont(ofSize: 14)
            let w = body(why, size: 12, color: .secondaryLabelColor)
            w.preferredMaxLayoutWidth = 330
            let text = vstack([n, w], spacing: 2)
            let ask = NSButton(title: "許可する", target: self, action: p == .microphone ? #selector(askMic) : #selector(askAccessibility))
            ask.bezelColor = .controlAccentColor
            ask.tag = 1
            let done = NSTextField(labelWithString: "✓ 許可済み")
            done.textColor = .systemGreen
            done.font = .boldSystemFont(ofSize: 13)
            done.tag = 2
            done.isHidden = true
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let r = NSStackView(views: [icon, text, spacer, ask, done])
            r.alignment = .centerY
            r.spacing = 12
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalToConstant: 520).isActive = true
            permRows[p] = r
            return r
        }
        return vstack([
            title("まず、2 つの許可をください"),
            body("Koe は、話した声を Mac の中だけで文字にします。そのために次の 2 つを使います。"),
            row(.microphone, symbol: "mic.fill", name: "マイク", why: "話した声を聞き取るため。音声は Mac の外に送りません"),
            row(.accessibility, symbol: "keyboard", name: "アクセシビリティ", why: "押して話すキーに気づき、話した文を入力欄に貼るため"),
            body("アクセシビリティは、システム設定で Koe のスイッチをオンにします。横に案内が出るので、そのとおりに進めてください。オンになると、ここも自動で進みます。", size: 12, color: .secondaryLabelColor),
        ], spacing: 18)
    }

    @objc private func askMic() {
        log("onboarding_ask", ["permission": "microphone"])
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { self.refreshPermissions() } }
        } else {
            openPermission(.microphone)
        }
    }

    @objc private func askAccessibility() {
        log("onboarding_ask", ["permission": "accessibility"])
        openPermission(.accessibility)
    }

    private func micView() -> NSView {
        let m = MeterView()
        meter = m
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: "自動（いまの既定のマイク: \(activeMicName())）")
        popup.lastItem?.representedObject = nil
        for name in micNames() {
            popup.addItem(withTitle: name)
            popup.lastItem?.representedObject = name
        }
        if let cur = currentMic(), let i = popup.itemArray.firstIndex(where: { $0.representedObject as? String == cur }) { popup.selectItem(at: i) }
        popup.target = self
        popup.action = #selector(micChanged(_:))
        let micRow = NSStackView(views: [NSTextField(labelWithString: "使うマイク:"), popup])
        micRow.spacing = 8
        let hint = body("バーが動かないときは: 上でマイクを選び直す／システム設定 → サウンド → 入力 で入力音量を上げる／会議アプリでミュートしているマイクからは音が来ません。", size: 12, color: .systemOrange)
        hint.isHidden = true
        hintLabel = hint
        return vstack([
            title("マイクを試します"),
            body("ふだんの声で、何か話してみてください（「テスト、テスト」など）。バーが緑になれば大丈夫です。"),
            m,
            micRow,
            status("● 声を待っています…"),
            hint,
        ], spacing: 16)
    }

    @objc private func micChanged(_ sender: NSPopUpButton) {
        let name = sender.selectedItem?.representedObject as? String
        log("onboarding_mic_selected", ["auto": name == nil])
        selectMic(name)
        micTest = MicTest()
        micPassed = false
        setStatus("● 声を待っています…", .secondaryLabelColor)
        hintLabel?.isHidden = true
        refreshButtons()
    }

    private func keyView() -> NSView {
        let cap = KeycapView(label: keyName)
        keycap = cap
        // 本番の録音中の表示（U-8）と同じ見た目の小さな帯
        let bars = LevelBarsView()
        bars.translatesAutoresizingMaskIntoConstraints = false
        bars.heights = HUDLayout.barHeights(.recording(since: Date(), locked: false, app: nil), level: 0, t: 0)
        pillBars = bars
        let pl = NSTextField(labelWithString: "（待機中）")
        pl.font = .systemFont(ofSize: 12.5, weight: .medium)
        pl.textColor = .white
        pillLabel = pl
        let pill = PillView(views: [bars, pl])
        let pillCap = body("本番では、画面の上にこの表示が出ます", size: 11, color: .secondaryLabelColor)
        let right = vstack([pill, pillCap], spacing: 6)
        right.alignment = .centerX
        let demo = NSStackView(views: [cap, right])
        demo.spacing = 40
        demo.alignment = .centerY

        let keyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (code, name) in [(54, "右⌘"), (61, "右⌥"), (62, "右⌃"), (63, "fn（地球儀）")] {
            keyPopup.addItem(withTitle: name)
            keyPopup.lastItem?.tag = code
        }
        keyPopup.selectItem(withTag: hotkeyCode())
        keyPopup.target = self
        keyPopup.action = #selector(keyChanged(_:))
        let keyRow = NSStackView(views: [body("このキーが使いにくいときは:", size: 12, color: .secondaryLabelColor), keyPopup])
        keyRow.spacing = 8

        return vstack([
            title("\(keyName) を押しながら話してみましょう"),
            body("押している間だけ録音します。ひと言話したら、キーを離します（ここでは練習なので貼りません）。"),
            demo,
            status(practiced ? "✓ " + PracticeResult.ok.message(key: keyName) : "● \(keyName) を押してください"),
            keyRow,
        ], spacing: 16)
    }

    @objc private func keyChanged(_ sender: NSPopUpButton) {
        guard let code = sender.selectedItem?.tag else { return }
        setHotkey(code)
        log("onboarding_key_changed", ["keyCode": code])
        go(.key)
    }

    private func pasteView() -> NSView {
        let open = NSButton(title: "テキストエディットを開く", target: self, action: #selector(openTextEdit))
        open.bezelColor = .controlAccentColor
        let tips = body("・長く話すときは \(keyName) を素早く 2 回押す（ロック録音。もう 1 回押すと終わります）\n・設定と困ったときは、メニューバーの吹き出しのアイコンから（この案内もそこから開き直せます）", size: 12, color: .secondaryLabelColor)
        tips.isHidden = true
        hintLabel = tips
        return vstack([
            title("ほかのアプリに貼ってみましょう"),
            body("① テキストエディット（Slack やメモでも大丈夫）の入力欄をクリックする\n② \(keyName) を押しながら話して、離す\n③ 話した文が、カーソルの位置に貼られます"),
            open, status(""), tips,
        ], spacing: 16)
    }

    @objc private func openTextEdit() {
        log("onboarding_open_textedit", [:])
        let url = PracticeFile.url()
        PracticeFile.prepare(url)   // 前に話した文を残さない
        let app = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    // 使うほど賢くする（#168）。何をするか・何をどこへ送るかを先に見せ、使えるかを確かめてから「有効にする」を出す
    private func improveView() -> NSView {
        let enable = NSButton(title: "有効にする", target: self, action: #selector(enableImproveTapped))
        enable.bezelColor = .controlAccentColor
        let preview = NSButton(title: "送る内容を見る", target: self, action: #selector(previewImproveTapped))
        let row = NSStackView(views: [enable, preview])
        row.isHidden = true
        improveButtons = row
        improveEnableButton = enable
        let st = status(ImproveStepText.checking)
        let views: [NSView] = [
            title(ImproveStepText.title),
            body(ImproveStepText.what),
            body(ImproveStepText.sent, size: 12, color: .secondaryLabelColor),
            row, st,
        ]
        improveReadiness { [weak self] r in self?.showImproveReadiness(r) }
        return vstack(views, spacing: 14)
    }

    private func showImproveReadiness(_ r: ImproveReadiness) {
        guard step == .improve else { return }
        log("onboarding_improve_ready", ["ready": r.canEnable])
        if improveEnabled() { return setStatus(ImproveStepText.enabled, .systemGreen) }
        // 使えないときは「あとで」だけ（設定のしかたを出す）
        improveButtons?.isHidden = false
        improveEnableButton?.isHidden = !r.canEnable
        setStatus(r.message, r.canEnable ? .secondaryLabelColor : .systemOrange)
    }

    @objc private func enableImproveTapped() {
        enableImprove()   // 送るものと送り先の確認を出す。「オンにする」を押したときだけオンになる
        guard improveEnabled() else { return }
        improveEnableButton?.isHidden = true
        setStatus(ImproveStepText.enabled, .systemGreen)
        refreshButtons()
    }

    @objc private func previewImproveTapped() {
        previewImprove { [weak self] in
            self?.setStatus("まだ送る発話はありません。有効にすると、話した分がたまってから送ります（送る前に、メニューの「改善ループで送る内容を見る…」でいつでも確かめられます）", .secondaryLabelColor)
        }
    }

    // MARK: 窓

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Koe をはじめる"
        w.isReleasedWhenClosed = false
        w.delegate = self

        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.lineBreakMode = .byTruncatingTail
        modelBar.style = .bar
        modelBar.isIndeterminate = false
        modelBar.minValue = 0
        modelBar.maxValue = 100
        modelBar.controlSize = .small
        modelBar.translatesAutoresizingMaskIntoConstraints = false
        modelBar.widthAnchor.constraint(equalToConstant: 520).isActive = true

        backButton.title = "戻る"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(previousStep)
        nextButton.bezelStyle = .rounded
        nextButton.target = self
        nextButton.action = #selector(nextStep)
        laterButton.title = "あとで"
        laterButton.bezelStyle = .rounded
        laterButton.target = self
        laterButton.action = #selector(later)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [laterButton, spacer, backButton, nextButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalToConstant: 520).isActive = true

        content.translatesAutoresizingMaskIntoConstraints = false
        content.widthAnchor.constraint(equalToConstant: 520).isActive = true
        content.heightAnchor.constraint(equalToConstant: 340).isActive = true

        let sep1 = NSBox(), sep2 = NSBox()
        sep1.boxType = .separator; sep2.boxType = .separator
        for s in [sep1, sep2] { s.translatesAutoresizingMaskIntoConstraints = false; s.widthAnchor.constraint(equalToConstant: 520).isActive = true }

        let root = NSStackView(views: [stepsLabel, sep1, content, sep2, modelLabel, modelBar, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 40, bottom: 18, right: 40)
        root.setCustomSpacing(18, after: sep1)
        root.setCustomSpacing(6, after: modelLabel)
        root.setCustomSpacing(16, after: modelBar)
        w.contentView = root
        window = w
    }
}

// マイクテストの横長のバー（声の大きさ。しきい値を越えたら緑）
final class MeterView: NSView {
    var level: Float = 0 { didSet { needsDisplay = true } }
    var passed = false { didSet { if passed != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 520).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = max(bounds.height, bounds.width * CGFloat(level))
        let on = passed || level >= MicTest.threshold
        (on ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height), xRadius: r, yRadius: r).fill()
        // しきい値の目盛り
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: bounds.width * CGFloat(MicTest.threshold) - 0.5, y: 2, width: 1, height: bounds.height - 4).fill()
    }
}

// キーの絵。押している間は色が付く
final class KeycapView: NSView {
    var pressed = false { didSet { needsDisplay = true } }
    private let label: String

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 120).isActive = true
        heightAnchor.constraint(equalToConstant: 72).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: pressed ? 2 : 4).offsetBy(dx: 0, dy: pressed ? -2 : 0)
        let shadow = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2).offsetBy(dx: 0, dy: -2), xRadius: 12, yRadius: 12)
        NSColor.tertiaryLabelColor.setFill()
        if !pressed { shadow.fill() }
        let p = NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12)
        (pressed ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
        p.fill()
        NSColor.separatorColor.setStroke()
        p.lineWidth = 1
        p.stroke()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: pressed ? NSColor.white : NSColor.labelColor,
        ]
        let s = NSAttributedString(string: label, attributes: attrs)
        let size = s.size()
        s.draw(at: NSPoint(x: inset.midX - size.width / 2, y: inset.midY - size.height / 2))
    }
}

// 録音中の表示（U-8）と同じ形の帯
final class PillView: NSVisualEffectView {
    init(views: [NSView]) {
        super.init(frame: .zero)
        material = .hudWindow
        appearance = NSAppearance(named: .vibrantDark)
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        let row = NSStackView(views: views)
        row.spacing = 8
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.heightAnchor.constraint(equalToConstant: 32),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
