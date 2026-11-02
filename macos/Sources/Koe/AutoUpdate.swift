import Foundation

// 「新しい版を自動で入れる」（既定オフ。メニューでオンにした人だけ）。いつ入れてよいかの判定だけを持つ。
// 入れ方（ダウンロード・署名の検証・入れ替え）は手で押した更新と同じ UpdateInstall で、検証の基準も同じ
enum AutoUpdate {
    static let key = "autoUpdate"
    static let failedKey = "autoUpdateFailedVersion"     // 署名を確かめられなかった版（次の版まで試さない）
    static let installedKey = "autoUpdateInstalled"      // 入れ替えを始めた版（起動し直したあとに知らせる）
    static let quietAfterUse: TimeInterval = 10 * 60     // 最後に押した・貼ったときから
    static let retryAfterFailure: TimeInterval = 3600    // ダウンロード・取り出しの失敗はしばらく置いてやり直す

    enum Decision: Equatable {
        case off, none
        case install
        case wait(String)     // あとでもう一度見る（busy / recent / retry）
        case manual(String)   // 自動では入れず、今の案内（手で押す）に回す（regrant / summary）
        case skip(String)     // この版は入れない（verify_failed / no_changes）
    }

    // summaryKnown: その版の CHANGELOG の macOS の節を読めた（読めないと Re-grant の印の有無が分からない）
    static func decide(now: Date, enabled: Bool, available: String?, summaryKnown: Bool, requiresRegrant: Bool,
                       noChanges: Bool, busy: Bool, lastUsed: Date?, failedVersion: String?, retryAt: Date?) -> Decision {
        guard enabled else { return .off }
        guard let available else { return .none }
        if failedVersion == available { return .skip("verify_failed") }
        guard summaryKnown else { return .manual("summary") }
        // 署名が変わる版はアクセシビリティが外れるので、今の案内で本人に入れてもらう
        if requiresRegrant { return .manual("regrant") }
        if noChanges { return .skip("no_changes") }
        if busy { return .wait("busy") }
        if let lastUsed, now.timeIntervalSince(lastUsed) < quietAfterUse { return .wait("recent") }
        if let retryAt, now < retryAt { return .wait("retry") }
        return .install
    }

    // 入れ替える直前にもう一度: 録音中・文字起こし中・貼り付け中でなく、ダウンロードを始めてから一度も押していない
    static func canReplace(busy: Bool, lastUsed: Date?, startedAt: Date) -> Bool {
        guard !busy else { return false }
        if let lastUsed, lastUsed >= startedAt { return false }
        return true
    }

    // 起動し直したあとの知らせ。入れ替えを始めた版で起動していれば出す
    static func notice(installed: String?, current: String) -> String? {
        guard let installed, installed == current else { return nil }
        return "Koe を v\(current) に自動で更新しました"
    }

    static func verifyFailedNotice(_ version: String) -> String {
        "新しい版 v\(version) の署名を確かめられなかったので、入れませんでした（次の版を待ちます）"
    }
}
