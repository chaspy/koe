// test-sources: AutoRestart.swift ServerLifecycle.swift
import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
for enabled in [false, true] {
    for alive in [false, true] {
        for quit in [false, true] {
            for hasSession in [false, true] {
                let result = AutoRestart.action(enabled: enabled, alive: alive, quitRequested: quit, hasSession: hasSession)
                if !enabled || !hasSession { expect(result == .stop, "default off / missing session") }
                else if alive { expect(result == .wait, "never duplicate live app; deferred quit stays alive") }
                else if quit { expect(result == .stop, "explicit quit never restarts") }
                else { expect(result == .restart, "unexpected death restarts") }
            }
        }
    }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-restart-" + UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let plist = directory.appendingPathComponent("agents/restart.plist")
let sessionURL = directory.appendingPathComponent("session.json")
expect(!FileManager.default.fileExists(atPath: plist.path), "no agent by default")
var commands: [[String]] = []
try AutoRestart.enable(executable: "/Applications/Example Koe.app/Contents/MacOS/Koe",
                       bundle: "/Applications/Example Koe.app", destination: plist, session: sessionURL,
                       domain: "gui/123", run: { commands.append($0) })
let data = try Data(contentsOf: plist)
guard let content = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
    fatalError("plist must be a dictionary")
}
expect(content["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false], "only unsuccessful exit is kept alive")
expect(content["ThrottleInterval"] as? Int == 30, "avoid restart storm")
expect(content["ProgramArguments"] as? [String] == ["/Applications/Example Koe.app/Contents/MacOS/Koe", "--auto-restart-agent", "/Applications/Example Koe.app", plist.path, sessionURL.path], "paths are arguments, not shell fragments")
expect(commands == [["bootstrap", "gui/123", plist.path]], "explicit enable registers exact plist")
try AutoRestart.disable(destination: plist, domain: "gui/123", run: {
    expect(!FileManager.default.fileExists(atPath: plist.path), "off prevents restart before bootout")
    commands.append($0)
})
expect(commands.last == ["bootout", "gui/123/\(AutoRestart.label)"], "off removes exact job")
expect(!FileManager.default.fileExists(atPath: plist.path), "off removes persistent plist")
enum Failure: Error { case expected }
do {
    try AutoRestart.enable(executable: "/example/Koe", bundle: "/example/Koe.app", destination: plist,
                           session: sessionURL, domain: "gui/123", run: { _ in throw Failure.expected })
    fatalError("bootstrap failure must surface")
} catch Failure.expected {}
expect(!FileManager.default.fileExists(atPath: plist.path), "failed enable restores off")
try AutoRestart.enable(executable: "/example/Koe", bundle: "/example/Koe.app", destination: plist,
                       session: sessionURL, domain: "gui/123", run: { _ in })
do {
    try AutoRestart.disable(destination: plist, domain: "gui/123", run: { _ in throw Failure.expected })
    fatalError("bootout failure must surface")
} catch Failure.expected {}
expect(!FileManager.default.fileExists(atPath: plist.path), "failed bootout still disarms watcher and next login")
let identity = ServerLifecycle.Identity.read(ProcessInfo.processInfo.processIdentifier)!
try AutoRestart.write(.init(identity: identity, quitRequested: false), to: sessionURL)
expect(AutoRestart.read(sessionURL)?.quitRequested == false, "new session resets quit intent")
try AutoRestart.write(.init(identity: identity, quitRequested: true), to: sessionURL)
expect(AutoRestart.read(sessionURL)?.quitRequested == true, "quit intent survives parent exit")
var savedQuit = false
var disarmed = 0
let session = AutoRestart.Session(identity: identity, quitRequested: false)
let recorded = try AutoRestart.protectQuit(session: session, pid: identity.pid,
    save: { savedQuit = $0.quitRequested }, disarm: { disarmed += 1 })
expect(recorded && savedQuit && disarmed == 0, "successful save does not change opt-in")
let fallback = try AutoRestart.protectQuit(session: session, pid: identity.pid,
    save: { _ in throw Failure.expected }, disarm: { disarmed += 1 })
expect(!fallback && disarmed == 1, "failed intent save disarms watcher")
do {
    _ = try AutoRestart.protectQuit(session: session, pid: identity.pid,
        save: { _ in throw Failure.expected }, disarm: { throw Failure.expected })
    fatalError("both failures must reach caller so termination is cancelled")
} catch Failure.expected {}
let retried = try AutoRestart.protectQuit(session: session, pid: identity.pid,
    save: { savedQuit = $0.quitRequested }, disarm: { fatalError("retry saved") })
expect(retried, "failure does not latch recorded; subsequent quit can retry")
_ = try AutoRestart.protectQuit(session: nil, pid: identity.pid,
    save: { _ in fatalError("no session") }, disarm: { disarmed += 1 })
expect(disarmed == 2, "unreadable session also disarms")
// No launchctl or LaunchAgents path is used by this test. All runners above are fakes.
print("auto restart tests passed")
