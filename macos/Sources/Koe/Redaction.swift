import Foundation

// 診断情報（Diagnostics.export）で伏せるもの。設定の秘密の値と、語・本文・個人の情報が入りうる値・欄
enum Redaction {
    static let secretWords = ["key", "token", "secret", "password", "auth"]
    // 値に語・本文・個人の情報が入りうる設定
    static let privateKeys: Set<String> = ["prompt", "contextPrompt", "improveCommand", "improveTokenCommand", "llmPrompt", "glossaryPath", "orgGlossary", "peopleSources"]
    // 動作の記録で、語や本文が入りうる欄
    static let privateEventFields: Set<String> = ["summary", "text", "raw", "pasted", "added", "terms", "error"]

    static func redactSetting(_ key: String, _ value: Any) -> String {
        let k = key.lowercased()
        if secretWords.contains(where: { k.contains($0) }) { return "***" }
        if privateKeys.contains(key) { return "（\(String(describing: value).count) 文字・伏せた）" }
        return String(describing: value).replacingOccurrences(of: "\n", with: " ")
    }

    static func redactEvent(_ line: String) -> String? {
        guard var e = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        for f in privateEventFields where e[f] != nil { e[f] = "（伏せた）" }
        guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }
}
