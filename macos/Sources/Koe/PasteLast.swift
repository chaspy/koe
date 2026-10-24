import AppKit
import Carbon.HIToolbox

// 直前の文をもう一度貼る（U-3）: ⌃⌥V とメニュー「最後の文を貼る」。貼る先は今のフォーカス。
//
// キーを「押して話すキー＋V」にしなかった理由: Koe は押して話すキーを見ているだけで、他のアプリへのキー入力は止めない。
// そのため押して話すキー＋V は、その V がそのまま前面のアプリにも届く。右⌘（既定）なら ⌘V（いつもの貼り付け）が二重に効き、
// 右⌥なら「√」が入り、右⌃ならターミナルの ⌃V（次の文字をそのまま入れる）になる。どのキーでもぶつかる。
// ⌃⌥V はシステムのホットキー（RegisterEventHotKey）として登録するので、Koe が受け取り、前面のアプリには届かない。
// macOS の既定のショートカットにも、よく使うアプリ（ブラウザ・Slack・Office・VS Code・ターミナル）の既定にも無く、
// 新しい許可も要らない（貼り付けはいつもどおりアクセシビリティの許可で行う）。
//
// Enter は送らない（ターミナルで同じコマンドを 2 回実行しないため）。
final class PasteLast: NSObject {
    static let shared = PasteLast()
    static let keyLabel = "⌃⌥V"

    // 貼る文: いちばん新しい文。空の文は飛ばす
    static func pick(_ recent: [(time: Date, text: String)]) -> (time: Date, text: String)? {
        recent.last(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    var onPaste: ((_ via: String) -> Void)?
    private(set) var registered = false
    private var ref: EventHotKeyRef?

    // 起動時に 1 回。設定 pasteLast がオフ（既定）なら何もしない。登録できなかった（他のアプリが先に使っている）ときはメニューからだけ使える
    func register() {
        guard Settings.pasteLast, ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // ほかのホットキー（MenuReach の ⌃⌥K）は受け取らずに次へ回す
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard PasteLast.hotKeyID(of: event) == 1 else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { PasteLast.shared.onPaste?("hotkey") }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4B6F_6556), id: 1)  // 'KoeV'
        let st = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
        registered = st == noErr
        if !registered { Events.log("paste_last_hotkey_unavailable", ["status": Int(st)]) }
    }

    static func hotKeyID(of event: EventRef?) -> UInt32? {
        guard let event else { return nil }
        var id = EventHotKeyID()
        let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        return st == noErr ? id.id : nil
    }

    lazy var item: NSMenuItem = {
        let i = NSMenuItem(title: "最後の文を貼る", action: #selector(fromMenu), keyEquivalent: "")
        i.target = self
        i.toolTip = "最後に文字起こしした文を、今のカーソルの位置にもう一度貼ります（Enter は押しません）。どこからでも \(PasteLast.keyLabel) で同じことができます"
        return i
    }()

    // メニューを開くたびに: オフ（既定）なら出さない。キーが使えるときだけ ⌃⌥V を添える
    func refresh(hasText: Bool) {
        item.isHidden = !Settings.pasteLast
        item.isEnabled = hasText
        if registered {
            item.keyEquivalent = "v"
            item.keyEquivalentModifierMask = [.control, .option]
        }
    }

    // ⌃⌥V で呼ばれたとき、⌃⌥ を押したまま ⌘V を送ると、押されている修飾を見るアプリでは ⌃⌥⌘V になって貼れないことがある。
    // ⌃⌥ が離されるまで待ってから貼る（最大 maxWait 秒。離されなければそのまま貼る）。done には待った秒数と、離されたかを渡す
    static let maxWait: TimeInterval = 1.0
    static func holdsHotkeyModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskControl, .maskAlternate]).isEmpty
    }
    static func whenModifiersReleased(maxWait: TimeInterval = PasteLast.maxWait, poll: TimeInterval = 0.02,
                                      flags: @escaping () -> CGEventFlags = { CGEventSource.flagsState(.combinedSessionState) },
                                      done: @escaping (_ waited: TimeInterval, _ released: Bool) -> Void) {
        let start = Date()
        func tick() {
            let waited = Date().timeIntervalSince(start)
            if !holdsHotkeyModifiers(flags()) { return done(waited, true) }
            if waited >= maxWait { return done(waited, false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + poll, execute: tick)
        }
        tick()
    }

    @objc private func fromMenu() {
        // メニューが閉じて、元のアプリにフォーカスが戻ってから貼る
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.onPaste?("menu") }
    }
}
