import AppKit
import Carbon.HIToolbox

// メニューバーの Koe のアイコンが見えなくても、メニューを開けるようにする（#194）。
// ノッチのある MacBook でメニューバーの項目が多いと、Koe のアイコンがノッチの裏に隠れて押せなくなる
// （録音と貼り付けは動くが、設定・更新・最近の文字起こしに届かない）。
// - ⌃⌥K: どこからでもメニューを開く（RegisterEventHotKey。前面のアプリにはキーが届かない。許可は要らない）
// - Koe をもう一度開く（Finder・Spotlight・open -a Koe）: メニューを開く（applicationShouldHandleReopen）
// - アイコンがノッチの裏に隠れていたら、1 日 1 回まで知らせる（録音中は出さない）
// 記録は menu_opened の reason（shortcut / reopen / notch_notice）だけ。画面の中身は残さない
final class MenuReach: MenuBarNotice {
    static let shared = MenuReach()
    static let keyLabel = "⌃⌥K"
    static let hotKeyID: UInt32 = 2   // PasteLast は 1
    private static let shownDayKey = "notchNoticeDay"

    var onOpen: ((_ reason: String) -> Void)?
    private(set) var registered = false
    private var ref: EventHotKeyRef?

    // アイコンが見えないか。frame はアイコンの窓の画面上の位置（取れなければ nil）。
    // notch はノッチの横の範囲（auxiliaryTopLeftArea の右端〜auxiliaryTopRightArea の左端。ノッチが無ければ nil）
    static func hidden(item frame: NSRect?, screen: NSRect, notch: ClosedRange<CGFloat>?) -> Bool {
        guard let f = frame, f.width > 0, screen.intersects(f) else { return true }
        guard let n = notch else { return false }
        return f.maxX > n.lowerBound && f.minX < n.upperBound
    }

    static func notchRange(left: NSRect?, right: NSRect?) -> ClosedRange<CGFloat>? {
        guard let l = left, let r = right, !l.isEmpty, !r.isEmpty, l.maxX < r.minX else { return nil }
        return l.maxX...r.minX
    }

    // 知らせるか: 1 日 1 回まで、録音・文字起こし中は出さない。day は "yyyy-MM-dd"
    static func shouldNotify(hidden: Bool, today: String, lastShownDay: String?, busy: Bool) -> Bool {
        hidden && !busy && lastShownDay != today
    }

    static let noticeTitle = "Koe のアイコンがノッチの裏に隠れています"
    static let noticeDetail = "\(keyLabel) でもメニューを開けます。⌘ を押しながらメニューバーのアイコンをドラッグすると並びを変えられます"

    // 起動時に 1 回。ほかのアプリが先に ⌃⌥K を使っていたら登録できない（そのときは Koe をもう一度開けばメニューが出る）
    func register() {
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard PasteLast.hotKeyID(of: event) == MenuReach.hotKeyID else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MenuReach.shared.onOpen?("shortcut") }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4B6F_654B), id: Self.hotKeyID)  // 'KoeK'
        let st = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        registered = st == noErr
        if !registered { Events.log("menu_hotkey_unavailable", ["status": Int(st)]) }
    }

    var iconHidden: Bool {
        guard let b = statusItem?.button, let w = b.window else { return true }
        let screen = w.screen ?? NSScreen.main
        let notch: ClosedRange<CGFloat>?
        if #available(macOS 12.0, *) {
            notch = Self.notchRange(left: screen?.auxiliaryTopLeftArea, right: screen?.auxiliaryTopRightArea)
        } else {
            notch = nil
        }
        return Self.hidden(item: w.convertToScreen(b.convert(b.bounds, to: nil)), screen: screen?.frame ?? .zero, notch: notch)
    }

    // 起動時に 1 回: キーの登録、1 分ごとの確かめ（起動の 10 秒後にも 1 回）。開くのは statusItem のメニュー
    func setUp(statusItem: NSStatusItem, busy: @escaping () -> Bool, lastUsed: @escaping () -> Date?) {
        onOpen = { [weak self, weak statusItem] reason in
            guard let self, let menu = statusItem?.menu else { return }
            self.open(menu, reason: reason)
        }
        register()
        start(statusItem: statusItem, busy: busy, lastUsed: lastUsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check() }
    }

    // メニューを開く。アイコンが見えていればアイコンから、見えなければマウスの位置に出す
    func open(_ menu: NSMenu, reason: String) {
        Events.log("menu_opened", ["reason": reason])
        if !iconHidden, let b = statusItem?.button {
            b.performClick(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    override func check() {
        guard !isShowing else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let today = f.string(from: Date())
        guard Self.shouldNotify(hidden: iconHidden, today: today,
                                lastShownDay: Settings.defaults.string(forKey: Self.shownDayKey), busy: busy()) else { return }
        Settings.defaults.set(today, forKey: Self.shownDayKey)
        Events.log("notch_notice")
        present(title: Self.noticeTitle, detail: Self.noticeDetail, detailLines: 3, width: 360,
                buttons: [button("閉じる", #selector(dismiss)), button("メニューを開く", #selector(openFromNotice))], hideAfter: 15)
    }

    @objc private func openFromNotice() {
        dismiss()
        onOpen?("notch_notice")
    }
}
