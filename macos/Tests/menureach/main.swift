// test-sources: MenuReach.swift MenuBarNotice.swift PasteLast.swift ../../Tests/TestSupport.swift
// make test: Sources/Koe/MenuReach.swift の単体テスト。画面の位置は合成の数値だけを使う
import AppKit

enum Settings { static var pasteLast = true; static let defaults = UserDefaults(suiteName: "koe-test-menureach")! }
enum Events { static func log(_ type: String, _ extra: [String: Any] = [:]) {} }

// 1512 pt 幅の画面、ノッチは 662〜850 のあたり（実際に隠れていた例: x=792, w=36）
let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
let left = NSRect(x: 0, y: 950, width: 662, height: 32), right = NSRect(x: 850, y: 950, width: 662, height: 32)
let notch = MenuReach.notchRange(left: left, right: right)
check(notch == 662...850, "ノッチの範囲: \(String(describing: notch))")
check(MenuReach.notchRange(left: nil, right: nil) == nil && MenuReach.notchRange(left: .zero, right: right) == nil, "ノッチが無い")

check(MenuReach.hidden(item: NSRect(x: 792, y: 950, width: 36, height: 32), screen: screen, notch: notch), "ノッチの裏は隠れている")
check(MenuReach.hidden(item: NSRect(x: 840, y: 950, width: 36, height: 32), screen: screen, notch: notch), "ノッチに少しかかっても隠れている")
check(!MenuReach.hidden(item: NSRect(x: 1200, y: 950, width: 36, height: 32), screen: screen, notch: notch), "右側に見えている")
check(!MenuReach.hidden(item: NSRect(x: 792, y: 950, width: 36, height: 32), screen: screen, notch: nil), "ノッチの無い画面")
check(MenuReach.hidden(item: nil, screen: screen, notch: notch), "位置が取れない")
check(MenuReach.hidden(item: NSRect(x: -100, y: 950, width: 0, height: 32), screen: screen, notch: nil), "幅 0")
check(MenuReach.hidden(item: NSRect(x: 3000, y: 950, width: 36, height: 32), screen: screen, notch: nil), "画面の外")

// 知らせ: 1 日 1 回まで、録音中は出さない、見えていれば出さない
check(MenuReach.shouldNotify(hidden: true, today: "2026-10-24", lastShownDay: nil, busy: false), "隠れていれば知らせる")
check(!MenuReach.shouldNotify(hidden: true, today: "2026-10-24", lastShownDay: "2026-10-24", busy: false), "同じ日は 2 回出さない")
check(MenuReach.shouldNotify(hidden: true, today: "2026-10-25", lastShownDay: "2026-10-24", busy: false), "次の日はまた")
check(!MenuReach.shouldNotify(hidden: true, today: "2026-10-24", lastShownDay: nil, busy: true), "録音中は出さない")
check(!MenuReach.shouldNotify(hidden: false, today: "2026-10-24", lastShownDay: nil, busy: false), "見えていれば出さない")
check(MenuReach.noticeDetail.contains("⌃⌥K"), "文面にキー")
check(MenuReach.hotKeyID != 1, "PasteLast と別の ID")
check(PasteLast.hotKeyID(of: nil) == nil, "イベントが無ければ ID なし")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("menureach: ok")
