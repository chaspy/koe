import AppKit
import ApplicationServices

// 録音中の小さな表示（U-8）。録音中／文字起こし中／失敗を、画面の上か文字カーソルの近くに小さく出す。
// - 録音中は声の大きさでバーが揺れる（いま録れているかが、メニューバーを見なくても分かる）
// - フォーカスを奪わない・クリックを邪魔しない（マウスは素通り）
// - 押してすぐ（右⌘+C などのショートカット）には出さない。showDelay だけ押し続けたら出す
// - メニューの「録音中の表示」で 画面の上（既定）／文字カーソルの近く／出さない を選べる
// 文字カーソルの位置はアクセシビリティで「位置」だけを読む（入力欄の中身は読まない）。どこにも書かない

// 声の大きさ（Recorder が録った塊ごとに計り、表示はそれを読むだけ）
enum AudioLevel {
    static func rms(_ pcm: [Int16]) -> Float {
        guard !pcm.isEmpty else { return 0 }
        var sum: Float = 0
        for v in pcm { let f = Float(v); sum += f * f }
        return (sum / Float(pcm.count)).squareRoot()
    }

    // -55 dBFS（静かな部屋）〜 -15 dBFS（大きめの声）を 0〜1 に
    static let floorDB: Float = -55, ceilDB: Float = -15
    static func normalized(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms / 32768)
        return min(1, max(0, (db - floorDB) / (ceilDB - floorDB)))
    }

    // 上がるときは速く、下がるときはゆっくり（バーがちらつかないように）
    static func smooth(_ prev: Float, _ new: Float) -> Float {
        prev + (new - prev) * (new > prev ? 0.6 : 0.15)
    }
}

// 見た目の案（どれを残すかは chaspy が触って選ぶ。選ばれなかった案は後で消す）。既定はオフ（新しい機能は既定オフで出す）
//   defaults write io.github.chaspy.koe recordingIndicator pill|dot|wave   （off で消す）
enum IndicatorStyle: String, CaseIterable {
    case off, pill, dot, wave

    var label: String {
        switch self {
        case .off: return "出さない（既定）"
        case .pill: return "案 A: 帯（バー＋「録音中 → アプリ」）"
        case .dot: return "案 B: 点（小さな丸が声で脈打つ。文字なし）"
        case .wave: return "案 C: 波（横長の波形が流れる）"
        }
    }

    // 位置を選んでいないときの、案ごとの置き場所
    var defaultPosition: IndicatorPosition {
        switch self {
        case .dot: return .caret
        case .wave: return .bottom
        default: return .top
        }
    }

    static let key = "recordingIndicator"
    // メニューの「録音中の表示」は、キーを一度でも書いた人にだけ出す（defaults write … recordingIndicator pill など）。
    // メニューで「出さない」を選んでも off が書かれるので、メニューは消えずに戻せる
    static var menuVisible: Bool { UserDefaults.standard.object(forKey: key) != nil }
    static var current: IndicatorStyle {
        get {
            // 前の版の値（top / caret）は帯として読む
            switch UserDefaults.standard.string(forKey: key) {
            case "top", "caret": return .pill
            case let v?: return IndicatorStyle(rawValue: v) ?? .off
            case nil: return .off
            }
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum IndicatorPosition: String, CaseIterable {
    case top, caret, bottom

    var label: String {
        switch self {
        case .top: return "画面の上"
        case .caret: return "文字カーソルの近く（取れないアプリでは画面の上）"
        case .bottom: return "画面の下"
        }
    }

    static let key = "recordingIndicatorPosition"
    static func current(for style: IndicatorStyle) -> IndicatorPosition {
        UserDefaults.standard.string(forKey: key).flatMap(IndicatorPosition.init(rawValue:)) ?? style.defaultPosition
    }
    static func set(_ p: IndicatorPosition) { UserDefaults.standard.set(p.rawValue, forKey: key) }
}

enum HUDState: Equatable {
    case idle
    case recording(since: Date, locked: Bool, app: String?)
    case transcribing
    case failed(String)

    // メニューバーと同じ材料から決める。録音中が最優先（文字起こし中に次を話し始めることがある）
    static func from(recordingSince: Date?, locked: Bool, app: String?, busy: Int) -> HUDState {
        if let s = recordingSince { return .recording(since: s, locked: locked, app: app) }
        return busy > 0 ? .transcribing : .idle
    }

    // 録り始めたアプリの名前（録音中に別のアプリへ移っても、貼り先は録り始めたアプリ）
    static func appName(bundleID: String?) -> String? {
        guard let id = bundleID, !id.isEmpty else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
    }
}

enum HUDLayout {
    static let showDelay: TimeInterval = 0.3   // これより短い押下（ショートカット）では出さない
    static let failSeconds: TimeInterval = 2.5
    static let margin: CGFloat = 8

    static func text(_ s: HUDState, now: Date) -> String {
        switch s {
        case .idle: return ""
        case let .recording(since, locked, app):
            let to = app.map { " → \($0)" } ?? ""
            return locked ? "ロック録音中 \(elapsed(now.timeIntervalSince(since)))" : "録音中\(to)"
        case .transcribing: return "文字起こし中…"
        case .failed(let m): return m
        }
    }

    static func elapsed(_ s: TimeInterval) -> String {
        let t = max(0, Int(s))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // 出す場所（Cocoa の座標）。文字カーソルが分かればその行のすぐ下（入りきらなければ上）、分からなければ画面の上の真ん中。
    // 画面の下を選んだときは下の真ん中（Dock の上）
    static func origin(size: CGSize, caret: CGRect?, visible: CGRect, bottom: Bool = false) -> CGPoint {
        if bottom { return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + margin * 3) }
        if let c = caret, visible.intersects(c.insetBy(dx: -1, dy: -1)) {
            let x = min(max(c.minX, visible.minX + margin), visible.maxX - size.width - margin)
            let below = c.minY - margin - size.height
            let y = below >= visible.minY + margin ? below : min(c.maxY + margin, visible.maxY - size.height - margin)
            return CGPoint(x: x, y: y)
        }
        return CGPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - margin)
    }

    // バーの高さ（0〜1）。録音中は声の大きさ、文字起こし中は左から右へ流れる波
    static let bars = 5
    static func barHeights(_ s: HUDState, level: Float, t: TimeInterval) -> [Float] {
        let weights: [Float] = [0.55, 0.8, 1.0, 0.8, 0.55]
        switch s {
        case .recording:
            return (0..<bars).map { i in
                let wobble = 0.85 + 0.15 * Float(sin(t * 9 + Double(i) * 1.3))
                return max(0.22, min(1, level * weights[i] * wobble))
            }
        case .transcribing:
            return (0..<bars).map { i in 0.25 + 0.5 * Float((sin(t * 6 - Double(i) * 0.9) + 1) / 2) }
        default:
            return []
        }
    }
}

// 文字カーソルの位置（アクセシビリティ。位置だけ読み、中身は読まない）。0.1 秒で諦める。
// 別のスレッドから呼ぶので NSScreen には触らない。主画面の高さはメインで取って渡す
enum CaretLocator {
    static func caretRect(primaryHeight: CGFloat) -> CGRect? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        // 型 ID を確かめた後なので、そのまま AXUIElement として扱える
        let element = unsafeBitCast(el, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.1)
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let r = range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, r, &bounds) == .success,
              let b = bounds, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // 型 ID を確かめた後なので、そのまま AXValue として扱える
        guard AXValueGetValue(unsafeBitCast(b, to: AXValue.self), .cgRect, &rect) else { return nil }
        return cocoa(rect, primaryHeight: primaryHeight)
    }

    // AX は主画面の左上が原点・下向き。Cocoa（左下が原点・上向き）に直す。おかしな大きさは捨てる
    static func cocoa(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect? {
        guard rect.height > 0, rect.height < 200 else { return nil }
        return CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: max(rect.width, 1), height: rect.height)
    }
}

// バーを描く
final class LevelBarsView: NSView {
    var heights: [Float] = [] { didSet { needsDisplay = true } }
    var color: NSColor = .systemRed
    static let barWidth: CGFloat = 3, gap: CGFloat = 2.5, maxHeight: CGFloat = 16

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(HUDLayout.bars) * (Self.barWidth + Self.gap) - Self.gap, height: Self.maxHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        for (i, h) in heights.enumerated() {
            let height = max(Self.barWidth, CGFloat(h) * Self.maxHeight)
            let x = CGFloat(i) * (Self.barWidth + Self.gap)
            let r = NSRect(x: x, y: (bounds.height - height) / 2, width: Self.barWidth, height: height)
            NSBezierPath(roundedRect: r, xRadius: Self.barWidth / 2, yRadius: Self.barWidth / 2).fill()
        }
    }
}

// 案 B: 小さな丸。録音中は赤い点のまわりの輪が声で広がる。文字起こし中は橙の輪が回る。失敗は黄色の ⚠
final class DotView: NSView {
    var state: HUDState = .idle { didSet { needsDisplay = true } }
    var level: Float = 0 { didSet { needsDisplay = true } }
    var t: TimeInterval = 0
    static let size: CGFloat = 30

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        NSColor(white: 0.1, alpha: 0.75).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        func circle(_ r: CGFloat) -> NSBezierPath { NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        switch state {
        case .recording(_, let locked, _):
            let color: NSColor = locked ? .systemOrange : .systemRed
            color.withAlphaComponent(0.35).setFill()
            circle(5 + CGFloat(level) * 8).fill()
            color.setFill()
            circle(5).fill()
        case .transcribing:
            let arc = NSBezierPath()
            let start = CGFloat((t * 360).truncatingRemainder(dividingBy: 360))
            arc.appendArc(withCenter: c, radius: 8, startAngle: start, endAngle: start + 250)
            arc.lineWidth = 2.5
            arc.lineCapStyle = .round
            NSColor.systemOrange.setStroke()
            arc.stroke()
        case .failed:
            let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            NSColor.systemYellow.set()
            if let img {
                let tinted = NSImage(size: img.size, flipped: false) { r in img.draw(in: r); NSColor.systemYellow.set(); r.fill(using: .sourceAtop); return true }
                tinted.draw(at: NSPoint(x: c.x - img.size.width / 2, y: c.y - img.size.height / 2), from: .zero, operation: .sourceOver, fraction: 1)
            }
        case .idle:
            break
        }
    }
}

// 案 C: 横長の波形。直近の声の大きさが右から左へ流れる。文字起こし中は波が走る
final class WaveView: NSView {
    static let count = 44
    var history = [Float](repeating: 0, count: WaveView.count) { didSet { needsDisplay = true } }
    var color: NSColor = .systemRed

    override var intrinsicContentSize: NSSize { NSSize(width: CGFloat(Self.count) * 4.5, height: 22) }

    func push(_ v: Float) {
        history.removeFirst()
        history.append(v)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        let step = bounds.width / CGFloat(history.count)
        for (i, v) in history.enumerated() {
            let h = max(2.5, CGFloat(v) * bounds.height)
            let r = NSRect(x: CGFloat(i) * step + 0.5, y: (bounds.height - h) / 2, width: max(1.5, step - 1.5), height: h)
            NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
        }
    }
}

// マウスを素通しし、キーも取らない窓
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class RecordingHUD {
    // 今の声の大きさ（0〜 の RMS。Recorder から読む）
    var level: () -> Float = { 0 }

    private var state: HUDState = .idle
    private var failure: (message: String, until: Date)?
    private var panel: HUDPanel?
    private var builtStyle: IndicatorStyle?
    private let bars = LevelBarsView()
    private let dot = DotView()
    private let wave = WaveView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var timer: Timer?
    private var showAt: Date?
    private var caret: CGRect?
    private var smoothed: Float = 0
    private var shownText: String?
    private var hiding = false

    private var style: IndicatorStyle { IndicatorStyle.current }

    // render() から毎回呼ばれる。変わったときだけ動く
    func update(_ s: HUDState) {
        if style == .off { state = .idle; failure = nil; hide(); return }
        guard s != state else { return }
        let wasRecording: Bool = { if case .recording = state { return true }; return false }()
        state = s
        if case .recording = s, !wasRecording {
            failure = nil
            showAt = Date().addingTimeInterval(HUDLayout.showDelay)
            caret = nil
            wave.history = [Float](repeating: 0, count: WaveView.count)
            if IndicatorPosition.current(for: style) == .caret, let h = NSScreen.screens.first?.frame.height {
                DispatchQueue.global(qos: .userInteractive).async {
                    let r = CaretLocator.caretRect(primaryHeight: h)
                    DispatchQueue.main.async { if case .recording = self.state { self.caret = r; self.place() } }
                }
            }
        } else if case .transcribing = s, wasRecording {
            showAt = nil   // 録音から続けて出す（短い押下で出ていなければ、ここから出る）
        }
        startTimer()
        // 録音を終えると「録音中でない」→「文字起こし中」が続けて来る。消すのは次の tick に回してちらつかせない
        if s != .idle { tick() }
    }

    // 失敗を少しの間だけ出す（失敗音と同じとき）
    func flashFailure(_ message: String) {
        guard style != .off else { return }
        failure = (message, Date().addingTimeInterval(HUDLayout.failSeconds))
        showAt = nil
        startTimer()
        tick()
    }

    private var effective: HUDState {
        if case .recording = state { return state }
        if let f = failure, Date() < f.until { return .failed(f.message) }
        return state
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)   // メニューを開いている間も揺らす
    }

    private func tick() {
        let s = effective
        if case .idle = s { failure = nil; hide(); return }
        if let at = showAt, Date() < at { return }
        let now = Date()
        let t = now.timeIntervalSinceReferenceDate
        smoothed = AudioLevel.smooth(smoothed, AudioLevel.normalized(rms: level()))
        let p = panel(for: style)
        let text = updateContent(s, text: HUDLayout.text(s, now: now), t: t)
        if text != shownText {
            shownText = text
            label.stringValue = text
            label.isHidden = text.isEmpty
            if style != .dot { p.setContentSize(p.contentView!.fittingSize) }
            place()
        }
        reveal(p)
    }

    private static func color(_ s: HUDState) -> NSColor {
        switch s {
        case .recording(_, let locked, _): return locked ? .systemOrange : .systemRed
        case .transcribing: return .systemOrange
        default: return .systemYellow
        }
    }

    // 見た目の案ごとに中身（バー・点・波）を動かし、出す文字を返す
    private func updateContent(_ s: HUDState, text: String, t: TimeInterval) -> String {
        let color = Self.color(s)
        var text = text
        switch style {
        case .pill, .off:
            let heights = HUDLayout.barHeights(s, level: smoothed, t: t)
            bars.isHidden = heights.isEmpty
            bars.color = color
            bars.heights = heights
            setIcon(s)
        case .dot:
            dot.t = t
            dot.level = smoothed
            dot.state = s
            text = ""
        case .wave:
            wave.color = color
            switch s {
            case .recording: wave.push(smoothed)
            case .transcribing: wave.history = (0..<WaveView.count).map { i in 0.15 + 0.35 * Float((sin(t * 7 - Double(i) * 0.35) + 1) / 2) }
            default: break
            }
            wave.isHidden = { if case .failed = s { return true }; return false }()
            setIcon(s)
            // 波の案は、ロック録音の経過時間と失敗だけ文字で出す
            if case .recording(_, let locked, _) = s, !locked { text = "" }
            if case .transcribing = s { text = "" }
        }
        return text
    }

    // まだ出ていなければふわっと出す。消えかけていたら戻す
    private func reveal(_ p: NSPanel) {
        if !p.isVisible {
            place()
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        } else if hiding {
            hiding = false
            NSAnimationContext.runAnimationGroup { $0.duration = 0.08; p.animator().alphaValue = 1 }
        }
    }

    private func setIcon(_ s: HUDState) {
        if case .failed = s {
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            icon.contentTintColor = .systemYellow
        } else {
            icon.isHidden = true
        }
    }

    private func place() {
        guard let p = panel else { return }
        let pos = IndicatorPosition.current(for: style)
        let c = pos == .caret ? caret : nil
        let mouse = NSEvent.mouseLocation
        let screen = c.flatMap { c in NSScreen.screens.first { $0.frame.intersects(c) } }
            ?? NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        p.setFrameOrigin(HUDLayout.origin(size: p.frame.size, caret: c, visible: visible, bottom: pos == .bottom))
    }

    private func hide() {
        timer?.invalidate()
        timer = nil
        showAt = nil
        shownText = nil
        smoothed = 0
        guard let p = panel, p.isVisible, !hiding else { return }
        hiding = true
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 },
                                             completionHandler: { if self.hiding { self.hiding = false; p.orderOut(nil) } })
    }

    // 案が変わったら中身を作り直す
    private func panel(for style: IndicatorStyle) -> HUDPanel {
        let p = panel ?? makePanel()
        guard builtStyle != style else { return p }
        builtStyle = style
        shownText = nil
        let views: [NSView]
        switch style {
        case .dot: views = [dot]
        case .wave: views = [icon, wave, label]
        default: views = [icon, bars, label]
        }
        for v in [dot, wave, icon, bars, label] as [NSView] { v.removeFromSuperview() }
        if style == .dot {
            let side = DotView.size + 4
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
            dot.frame = NSRect(x: 2, y: 2, width: DotView.size, height: DotView.size)
            holder.addSubview(dot)
            p.contentView = holder
            p.hasShadow = false
            p.setContentSize(NSSize(width: side, height: side))
            return p
        } else {
            let bg = NSVisualEffectView()
            bg.material = .hudWindow
            bg.appearance = NSAppearance(named: .vibrantDark)
            bg.state = .active
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 16
            bg.layer?.masksToBounds = true
            let row = NSStackView(views: views)
            row.spacing = 8
            row.alignment = .centerY
            row.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            row.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
                row.topAnchor.constraint(equalTo: bg.topAnchor),
                row.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
                row.heightAnchor.constraint(equalToConstant: 32),
            ])
            p.contentView = bg
            p.hasShadow = true
        }
        p.setContentSize(p.contentView!.fittingSize)
        return p
    }

    private func makePanel() -> HUDPanel {
        let p = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 32),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        bars.translatesAutoresizingMaskIntoConstraints = false
        wave.translatesAutoresizingMaskIntoConstraints = false
        panel = p
        return p
    }
}
