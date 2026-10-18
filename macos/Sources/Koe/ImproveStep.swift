import Foundation

// 初回の案内の最後の段「使うほど賢くする」（#168 の 1）の判定と文言。画面は OnboardingWindow.swift。
// 改善ループは既定オフのまま。オンにするのは、この段の「有効にする」から同意の確認を経たときだけ
enum ImproveReadiness: Equatable {
    case ready(target: String)       // 既定のコマンド（または設定した送り先）でそのまま使える
    case missingCommand(String)      // コマンドが見つからない（既定なら claude）
    case missingEndpoint             // api 型なのに送り先が無い

    // found: ログインシェルでそのプログラムが見つかるか（Koe は改善ループのコマンドを zsh -lc で動かす）
    static func evaluate(provider: String, command: String, endpoint: String, target: String,
                         found: (String) -> Bool) -> ImproveReadiness {
        if provider == "api" { return endpoint.isEmpty ? .missingEndpoint : .ready(target: target) }
        let prog = program(of: command)
        return !prog.isEmpty && found(prog) ? .ready(target: target) : .missingCommand(prog)
    }

    // コマンドの最初の語（環境変数の代入 `A=b claude -p` は飛ばす）。'…' か "…" で囲んだ語は、空白を含めて 1 語
    static func program(of command: String) -> String {
        words(command).first { !$0.contains("=") } ?? ""
    }

    private static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == " " {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else {
                cur.append(c)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    var canEnable: Bool { if case .ready = self { return true }; return false }

    // 段の下に出す一文
    var message: String {
        switch self {
        case .ready(let target):
            return "送り先: \(target)"
        case .missingCommand(let prog):
            return "このパソコンで \(prog.isEmpty ? "コマンド" : "「\(prog)」") が見つかりませんでした。Claude Code を入れるか、別の送り先を設定してから、"
                + "メニューの「使うほど賢くする（改善ループ）」で有効にできます。" + ImproveStepText.otherProvider
        case .missingEndpoint:
            return "送り先（improveEndpoint）が設定されていません。設定してから、メニューの「使うほど賢くする（改善ループ）」で有効にできます。"
                + ImproveStepText.otherProvider
        }
    }
}

enum ImproveStepText {
    static let title = "使うほど賢くする"
    static let what = "Koe が聞き間違えた語を AI に見つけてもらい、自分の辞書に足していきます。使うほど、よく使う語が正しく入るようになります。"
    static let sent = "送るもの: 直近の文字起こし（Claude Code に話したときは、送った文とその返答も）を、設定したコマンドに送ります。"
        + "既定は自分の Claude Code（claude -p）なので、新しいアカウントや追加の料金はいりません。音声は Mac から出ません。"
    static let otherProvider = "\n別の送り先の例: defaults write io.github.chaspy.koe improveProvider api と improveEndpoint（OpenAI 互換の URL）・improveModel。配布の設定ファイルでも設定できます。"
    static let enabled = "✓ 有効にしました。30 回話すごとに、録音していないときに辞書を育てます。メニューからいつでも止められます。"
    static let checking = "このパソコンで使えるか確かめています…"

    // この段を出すか。オンにするかがまだ決まっていない（本人・設定ファイル・MDM のどれも決めていない）ときだけ
    static func shows(undecided: Bool, enabled: Bool) -> Bool { undecided && !enabled }
}
