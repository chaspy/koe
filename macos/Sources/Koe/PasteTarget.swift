import Foundation

// 録音を始めたときと貼る瞬間とで、前面のアプリが違うか（windows/core の TargetChanged と同じ規則）。
// アプリ単位で比べる（同じアプリの別ウィンドウ・タブに移っただけなら貼る）。どちらかが分からないときは違うとしない
enum PasteTarget {
    static func changed(start: String?, now: String?) -> Bool {
        let a = (start ?? "").lowercased(), b = (now ?? "").lowercased()
        return !a.isEmpty && !b.isEmpty && a != b
    }

    // 貼る瞬間にどうするか（windows/core の FocusDecision と同じ規則）
    // paste: そのまま貼る / restore: 押したときのアプリとウィンドウを前に戻してから貼る / block: 貼らずにクリップボードに残す（target_changed）
    enum Decision: Equatable { case paste, restore, block }

    // 押してからこれより時間がたっていたら戻さない（話し始めの場所に、もう関心が無いかもしれない）
    static let maxRestoreAge: TimeInterval = 20

    static func decide(start: String?, now: String?, sincePress: TimeInterval, restoreEnabled: Bool) -> Decision {
        guard changed(start: start, now: now) else { return .paste }
        return restoreEnabled && sincePress <= maxRestoreAge ? .restore : .block
    }
}
