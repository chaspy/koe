// Compiled as main.swift by test_integration.py, never linked into Koe.
import Foundation
import Darwin

let args = CommandLine.arguments
if args.count == 5 && args[1] == "--auto-restart-agent" {
    exit(AutoRestart.watch(bundle: args[2], destination: URL(fileURLWithPath: args[3]), sessionURL: URL(fileURLWithPath: args[4])))
}
if args.count == 3 && args[1] == "--cleanup" {
    let directory = URL(fileURLWithPath: args[2])
    if let session = AutoRestart.read(directory.appendingPathComponent("session.json")) {
        let expected = directory.appendingPathComponent("Dummy.app/Contents/MacOS/Dummy").resolvingSymlinksInPath().path
        if URL(fileURLWithPath: session.identity.path).resolvingSymlinksInPath().path == expected {
            ServerLifecycle.stop(.init(parent: ServerLifecycle.Identity.read(getpid())!, server: session.identity))
            precondition(!session.identity.isCurrent, "test app must be gone")
        }
    }
    exit(0)
}
let root = Bundle.main.bundleURL.deletingLastPathComponent()
let sessionURL = root.appendingPathComponent("session.json")
let plist = root.appendingPathComponent("agent.plist")
let label = try String(contentsOf: root.appendingPathComponent("label"), encoding: .utf8)
precondition(label.hasPrefix("io.github.chaspy.koe.restart.test."))
let countURL = root.appendingPathComponent("count")
let count = (Int((try? String(contentsOf: countURL, encoding: .utf8)) ?? "0") ?? 0) + 1
let identity = ServerLifecycle.Identity.read(getpid())!
try AutoRestart.write(.init(identity: identity, quitRequested: false), to: sessionURL)
try String(count).write(to: countURL, atomically: true, encoding: .utf8)
if count == 1 {
    Thread.sleep(forTimeInterval: 2)
    exit(1)
}
enum Injected: Error { case save }
let deadline = Date().addingTimeInterval(120)
while Date() < deadline {
    if let request = try? String(contentsOf: root.appendingPathComponent("quit"), encoding: .utf8) {
        _ = try AutoRestart.protectQuit(session: AutoRestart.read(sessionURL), pid: getpid(), save: {
            if request == "save-failure" { throw Injected.save }
            try AutoRestart.write($0, to: sessionURL)
        }, disarm: {
            try AutoRestart.disable(destination: plist, domain: "gui/\(getuid())", jobLabel: label, run: AutoRestart.launchctl)
        })
        try Data().write(to: root.appendingPathComponent("finished"))
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
}
exit(0)
