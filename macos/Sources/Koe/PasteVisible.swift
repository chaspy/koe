import Foundation

// 貼った文が画面に出たか（iTerm の今のセッションの contents と比べる）。画面の中身も文も比べるのにだけ使い、どこにも書かない。
// 貼った文の末尾（正規化して最大 16 文字）が画面にあれば出たとする。
// - 正規化: NFKC（全角・半角をそろえる）にして、空白・改行・制御文字を除く（ターミナルの折り返し・Claude Code の字下げに左右されない）
// - Herdr などで画面が縦に分かれていると、1 行に左右のペインの中身が並ぶ。罫線（│ など）と改行で区切った断片を画面の順に並べ、
//   末尾が 1 つの断片に入っているか、「ある断片の終わり + その後ろの断片（丸ごと）… + さらに後ろの断片の始まり」で組めれば出たとする
//   （ペインの中で折り返すと、末尾は同じペインの次の行＝後ろの断片に続く）。
//   iTerm の contents は端まで埋まった行を次の行とつなげて返すので、行の数や位置には頼らない
enum PasteVisible {
    static let tailLength = 16
    static let dividers: Set<Character> = ["│", "┃", "║", "╎", "╏", "┆", "┇", "┊", "┋", "|"]

    static func normalize(_ s: String) -> String {
        String(s.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
                && $0.properties.generalCategory != .format
        }.map(Character.init))
    }

    // 初回の読み取りを測った値として使えるか。許可がまだ決まっていなかった（AEDeterminePermissionToAutomateTarget が noErr 以外）ときは、
    // 初回の読み取りの最中に macOS が許可のダイアログを出し、答えるまで戻らない。待った分が「出るまでの時間」に入る
    // （手元の Mac で、ダイアログで待った 8 秒が visible_ms 8006 として数えられた）ので、出たかどうかに関わらず
    // 測れなかった（visible_unknown の waited_permission）とする
    static func waitedPermission(permission: Int32, firstRead: Bool) -> Bool { firstRead && permission != 0 }

    static func tail(_ text: String) -> String {
        String(normalize(text).suffix(tailLength))
    }

    static func segments(_ screen: String) -> [String] {
        screen.split(whereSeparator: { $0 == "\n" || dividers.contains($0) }).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    static func visible(tail t: String, in screen: String) -> Bool {
        let t = Array(t)
        guard !t.isEmpty else { return false }
        let segs = segments(screen)
        let whole = String(t)
        if segs.contains(where: { $0.contains(whole) }) { return true }
        // reach[j] = 末尾の先頭 j 文字までを組めたときの、最後に使った断片の位置（いちばん前）
        var reach = [Int?](repeating: nil, count: t.count)
        for j in 1..<t.count {
            let head = String(t[..<j])
            reach[j] = segs.firstIndex { $0.hasSuffix(head) }
        }
        for j in 1..<t.count {
            guard let i = reach[j] else { continue }
            let rest = String(t[j...])
            for k in (i + 1)..<max(i + 1, segs.count) {
                let b = segs[k]
                if b.hasPrefix(rest) { return true }
                // 断片を丸ごと使って先へ進む（狭いペインで 3 行以上にまたがる）
                if rest.hasPrefix(b), j + b.count < t.count {
                    let n = j + b.count
                    if reach[n] == nil || reach[n]! > k { reach[n] = k }
                }
            }
        }
        return false
    }
}
