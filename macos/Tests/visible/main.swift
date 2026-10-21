// test-sources: PasteVisible.swift
// make test: Sources/Koe/PasteVisible.swift の単体テスト（貼った文の末尾が画面に出たか）
import Foundation

var failures = 0
func check(_ name: String, _ got: Bool, _ want: Bool) {
    if got != want { failures += 1; print("FAIL: \(name) got \(got)") }
}
func seen(_ text: String, _ screen: String) -> Bool { PasteVisible.visible(tail: PasteVisible.tail(text), in: screen) }

let text = "このファイルのテストを足しておいてください。終わったら教えて"
check("1 行にそのまま", seen(text, "$ ls\n> \(text)\n"), true)
check("tail は 16 文字", PasteVisible.tail(text).count == 16, true)
check("無い", seen(text, "$ ls\n> 別の話をしています\n"), false)
check("空の文", seen("", "何か"), false)
check("空白だけの文", seen("  \n", "何か"), false)
// 折り返し（Claude Code の入力欄・送った後の表示。続きの行は字下げされる）
check("折り返し", seen(text, "> このファイルのテストを足しておいてくださ\n  い。終わったら教えて\n"), true)
check("単語の区切りで折り返し", seen("please run make test and tell me", "> please run make\n  test and tell me\n"), true)
// 入力欄の枠
check("枠の中", seen(text, "╭──────╮\n│ > \(text)   │\n╰──────╯\n"), true)
check("枠の中で折り返し", seen(text, "│ > このファイルのテストを足しておいてくだ │\n│   さい。終わったら教えて                  │\n"), true)
// Herdr: 左右のペインが 1 行に並ぶ。右のペインの中で折り返す
let herdr = """
 spaces       │┌──────────────────────┐┌──────────────────────┐
 ● koe        ││ 別のペインの出力     ││ > このファイルのテス │
              ││ build ok             ││ トを足しておいてくだ │
              ││                      ││ さい。終わったら教え │
              ││                      ││ て                   │
"""
check("Herdr の右のペインで折り返し", seen(text, herdr), true)
check("Herdr で無い文", seen("デプロイの手順を教えて", herdr), false)
// iTerm の contents は端まで埋まった行を次の行とつなげて返す（Herdr は行を端まで描く）。行の区切りが無くても拾う
let merged = herdr.split(separator: "\n").joined()
check("Herdr の行がつながって返る", seen(text, merged), true)
// 並びが逆（後ろの断片に先頭が来る）は出たとしない
check("断片の順が逆", seen(text, "│ い。終わったら教えて │\n│ > このファイルのテストを足しておいてくださ │"), false)
// 全角・半角（NFKC）
check("全角英数", seen("ＡＢＣを直して", "> ABCを直して"), true)
check("半角カナ", seen("テストを回して", "> ﾃｽﾄを回して"), true)
// 末尾だけ違う（貼り付けが途中で切れた）
check("途中まで", seen(text, "> このファイルのテストを足しておいてください。終わったら"), false)

// 許可のダイアログで待った回（初回の読み取りで、許可がまだ決まっていなかった）は測れなかったとする
check("許可済みなら初回も測る", PasteVisible.waitedPermission(permission: 0, firstRead: true), false)
check("許可を聞いた初回は測らない（-1744）", PasteVisible.waitedPermission(permission: -1744, firstRead: true), true)
check("許可の状態が分からない初回も測らない", PasteVisible.waitedPermission(permission: -1750, firstRead: true), true)
check("2 回目からは測る", PasteVisible.waitedPermission(permission: -1744, firstRead: false), false)

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("visible: ok")
