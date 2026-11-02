import Foundation

// 落とした dmg から Koe.app を取り出し、署名を確かめ（UpdateVerify）、Koe が終わってから今の場所に入れ替えて起動し直す。
// 手で押した更新（Updater.install）と自動更新の両方がこれを使う。試し（Tests/updateinstall）からも同じものを呼ぶ
enum UpdateInstall {
    enum Failure: Error, Equatable {
        case mount, extract, verify(UpdateVerify.Failure), launch

        var reason: String {
            switch self {
            case .mount: return "mount"
            case .extract: return "extract"
            case .verify: return "verify"
            case .launch: return "launch"
            }
        }
        var message: String {
            switch self {
            case .mount: return "dmg を開けませんでした"
            case .extract: return "新しい版を取り出せませんでした"
            case .verify(let bad): return "新しい版の署名を確かめられなかったので、入れ替えませんでした（\(bad.message)）"
            case .launch: return "入れ替えを始められませんでした"
            }
        }
    }

    struct Staged { let work: URL; let app: URL }

    // downloaded: ダウンロードした dmg（一時ファイル。作業用のフォルダへ移す）。署名が通らなければ作業用のフォルダごと消す
    static func stage(downloaded tmp: URL, requirement: String = UpdateVerify.requirement) -> Result<Staged, Failure> {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("koe-update-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent("Koe.dmg")
        try? FileManager.default.moveItem(at: tmp, to: dmg)
        let mount = work.appendingPathComponent("mnt")
        guard run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path]) == 0 else {
            try? FileManager.default.removeItem(at: work)
            return .failure(.mount)
        }
        let staged = work.appendingPathComponent("Koe.app")
        let ok = run(["ditto", mount.appendingPathComponent("Koe.app").path, staged.path]) == 0
        _ = run(["hdiutil", "detach", "-quiet", mount.path])
        guard ok else {
            try? FileManager.default.removeItem(at: work)
            return .failure(.extract)
        }
        // Replace the app only with a bundle signed by Koe's Developer ID (UpdateVerify.swift)
        if let bad = UpdateVerify.check(appAt: staged, requirement: requirement) {
            try? FileManager.default.removeItem(at: work)
            return .failure(.verify(bad))
        }
        return .success(Staged(work: work, app: staged))
    }

    // pid の Koe が終わるのを待って target を staged で置き換え、relaunch（既定は open）で起動し直す。呼んだ側はこのあと終わる
    static func startReplace(_ s: Staged, target: String, pid: Int32, relaunch: String = "/usr/bin/open") throws {
        // Values are passed as arguments ($1 pid, $2 target, $3 staged app, $4 work dir, $5 relaunch), not put into the script
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.3; done
        rm -rf "$2" && ditto "$3" "$2"
        "$5" "$2"
        rm -rf "$4"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(pid), target, s.app.path, s.work.path, relaunch]
        try p.run()
    }

    // 入れ替えずにやめる（直前に録音が始まったときなど）
    static func discard(_ s: Staged) { try? FileManager.default.removeItem(at: s.work) }

    private static func run(_ args: [String]) -> Int32 {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return -1 }
        p.waitUntilExit(); return p.terminationStatus
    }
}
