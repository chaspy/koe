import Foundation

// open -n -g Koe.app --args --paste-test <目印> <結果ファイル> の判定（main.swift から呼ぶ）。
// 外から好きな文を Koe の許可で貼らせないよう、貼る文は固定で、外から受け取るのは英数字とハイフン 32 字までの目印だけ。
// 前面が TextEdit でなければ貼らない。結果は pasted / no_accessibility / not_textedit / bad_marker。文は記録しない
enum PasteTest {
    static let textEdit = "com.apple.TextEdit"

    static func validMarker(_ m: String) -> Bool {
        (1...32).contains(m.count)
            && m.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    // 貼ってよければ nil、だめならその理由（結果ファイルに書く語）
    static func refusal(marker: String, frontmost: String?, trusted: Bool) -> String? {
        if !validMarker(marker) { return "bad_marker" }
        if frontmost != textEdit { return "not_textedit" }
        if !trusted { return "no_accessibility" }
        return nil
    }

    static func text(_ marker: String) -> String { "Koe paste test \(marker)" }
}
