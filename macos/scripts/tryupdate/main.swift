// scripts/try_auto_update.sh から使う。本物の Koe は起動せず、UpdateInstall（アプリと同じ取り出し・署名の検証・入れ替え）を
// 127.0.0.1 の dmg と一時フォルダの target で動かす。
//   tryupdate <dmg の URL> <target.app> <case: busy|replace|verify-fail> <relaunch の記録先>
import Foundation

let args = CommandLine.arguments
guard args.count == 5, let url = URL(string: args[1]) else { print("usage: tryupdate <url> <target.app> <case> <relaunch-log>"); exit(2) }
let target = args[2], mode = args[3], relaunchLog = args[4]

func download(_ url: URL) -> URL? {
    let done = DispatchSemaphore(value: 0)
    var out: URL?
    URLSession.shared.downloadTask(with: url) { tmp, _, _ in
        if let tmp {
            let keep = FileManager.default.temporaryDirectory.appendingPathComponent("tryupdate-\(UUID().uuidString).dmg")
            try? FileManager.default.moveItem(at: tmp, to: keep)
            out = keep
        }
        done.signal()
    }.resume()
    done.wait()
    return out
}

guard let dmg = download(url) else { print("result: download_failed"); exit(1) }
let started = Date()
switch UpdateInstall.stage(downloaded: dmg) {
case .failure(let f):
    print("result: stage_failed reason=\(f.reason) message=\(f.message)")
    exit(mode == "verify-fail" ? 0 : 1)
case .success(let s):
    print("staged: \(s.app.lastPathComponent) verified")
    // 入れ替える直前の確認（アプリと同じ AutoUpdate.canReplace）。busy は録音が始まった場合
    let busy = mode == "busy"
    guard AutoUpdate.canReplace(busy: busy, lastUsed: nil, startedAt: started) else {
        UpdateInstall.discard(s)
        print("result: deferred work_removed=\(!FileManager.default.fileExists(atPath: s.work.path))")
        exit(mode == "busy" ? 0 : 1)
    }
    // Koe の代わりのプロセス。これが終わってから入れ替わる
    let koe = Process()
    koe.executableURL = URL(fileURLWithPath: "/bin/sleep"); koe.arguments = ["2"]
    try koe.run()
    // relaunch は本物の open ではなく、呼ばれた引数を書くだけのスクリプト（本物の Koe を起動しない）
    let recorder = FileManager.default.temporaryDirectory.appendingPathComponent("tryupdate-relaunch-\(UUID().uuidString).sh")
    try "#!/bin/sh\necho \"$1\" > '\(relaunchLog)'\n".write(to: recorder, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)
    try UpdateInstall.startReplace(s, target: target, pid: koe.processIdentifier, relaunch: recorder.path)
    print("result: replace_started (waiting for pid \(koe.processIdentifier))")
}
