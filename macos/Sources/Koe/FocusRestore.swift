import Cocoa

// 押した瞬間の前面のアプリ・ウィンドウ・フォーカスのある要素を覚え（Snapshot）、
// 貼る瞬間に前面が変わっていたら、そこへ戻す（BUG-FOCUS）。
// 戻すのはアクセシビリティ（AX）で行う。macOS 14 からは裏のアプリが NSRunningApplication.activate で
// 他のアプリを前に出せないことがあるので、AX の AXFrontmost・AXMain・AXRaise を使い、activate は補助にする。
// ウィンドウのタイトルや要素の中身は読まない（events にも書かない）。
enum FocusRestore {
    struct Snapshot {
        let pid: pid_t
        let bundleID: String
        let window: AXUIElement?
        let element: AXUIElement?
    }

    enum Result: Equatable {
        case restored(ms: Int)
        case failed(reason: String)  // app_gone / window_gone / not_frontmost
    }

    private static let queue = DispatchQueue(label: "io.github.chaspy.koe.focus", qos: .userInitiated)

    // ウィンドウと要素は、録音を始めた後に裏の queue で AX から取る（押した瞬間には pid と bundle id だけ）。
    // 負荷が高いと iTerm などが十数秒 AX に応答しないことがあり、メインで待つと録音の始まりが遅れるため。
    // done はメインで呼ぶ。取り終える前に貼る時点が来たら、snapshot 無し（no_snapshot）として今までどおり扱う
    static func capture(pid: pid_t, bundleID: String, done: @escaping (Snapshot) -> Void) {
        queue.async {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, axTimeout)  // 応答しないアプリで既定の約 6 秒を待たない
            let s = Snapshot(pid: pid, bundleID: bundleID,
                             window: element(ax, kAXFocusedWindowAttribute), element: element(ax, kAXFocusedUIElementAttribute))
            DispatchQueue.main.async { done(s) }
        }
    }

    // 戻せたかを、前に出るまで最大 timeout 秒待って確かめる。メインスレッドで呼ぶ（貼る直前）
    static func restore(_ s: Snapshot, timeout: TimeInterval = 0.8) -> Result {
        let t0 = Date()
        guard let app = NSRunningApplication(processIdentifier: s.pid), !app.isTerminated,
              (app.bundleIdentifier ?? "") == s.bundleID else { return .failed(reason: "app_gone") }
        if let w = s.window, !alive(w) { return .failed(reason: "window_gone") }
        let ax = AXUIElementCreateApplication(s.pid)
        AXUIElementSetMessagingTimeout(ax, axTimeout)
        if app.isHidden { app.unhide() }
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate()
        if let w = s.window {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        while Date().timeIntervalSince(t0) < timeout {
            if frontmost(ax), s.window.map({ focusedWindow(ax, is: $0) }) ?? true {
                // フォーカスのあった欄にも戻す（できなくても貼る。ウィンドウが前にあれば、たいていそこにある）
                if let e = s.element, alive(e) {
                    AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                }
                usleep(60_000)  // キーウィンドウが切り替わり終えるのを待つ（すぐ ⌘V を送ると前のアプリに届くことがある）
                return .restored(ms: Int(Date().timeIntervalSince(t0) * 1000))
            }
            usleep(20_000)
        }
        return .failed(reason: "not_frontmost")
    }

    private static let axTimeout: Float = 0.3

    private static func element(_ ax: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // 消えたウィンドウ・要素は、役割（AXRole）も読めなくなる
    private static func alive(_ e: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &v) == .success
    }

    private static func frontmost(_ ax: AXUIElement) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(ax, kAXFrontmostAttribute as CFString, &v) == .success && (v as? Bool) == true
    }

    private static func focusedWindow(_ ax: AXUIElement, is w: AXUIElement) -> Bool {
        guard let f = element(ax, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(f, w)
    }
}
