import Foundation

// 録音を始めたときと貼る瞬間とで、前面のアプリが違うか（windows/core の TargetChanged と同じ規則）。
// アプリ単位で比べる（同じアプリの別ウィンドウ・タブに移っただけなら貼る）。どちらかが分からないときは違うとしない
enum PasteTarget {
    static func changed(start: String?, now: String?) -> Bool {
        let a = (start ?? "").lowercased(), b = (now ?? "").lowercased()
        return !a.isEmpty && !b.isEmpty && a != b
    }
}
