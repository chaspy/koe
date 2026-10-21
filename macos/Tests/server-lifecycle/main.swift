// test-sources: ServerLifecycle.swift
import Darwin
import Foundation

// These modes create only isolated test children; the production app never starts.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--watch-server-lifetime" {
    ServerLifecycle.watch(URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--fixture-parent" {
    let directory = URL(fileURLWithPath: CommandLine.arguments[2])
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    let url = directory.appendingPathComponent("fixture.json")
    try ServerLifecycle.save(.init(parent: ServerLifecycle.Identity.read(getpid())!,
                                   server: ServerLifecycle.Identity.read(child.processIdentifier)!), at: url)
    let pipe = Pipe()
    let watcher = Process()
    watcher.executableURL = URL(fileURLWithPath: CommandLine.arguments[3])
    watcher.arguments = ["--watch-server-lifetime", url.path]
    watcher.standardInput = pipe
    try watcher.run()
    pipe.fileHandleForReading.closeFile()
    try Data("ready".utf8).write(to: directory.appendingPathComponent("ready"))
    withExtendedLifetime((pipe, watcher, child)) {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        pipe.fileHandleForWriting.closeFile()
        child.waitUntilExit()
        watcher.waitUntilExit()
    }
    exit(0)
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("koe-lifecycle-" + UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let marker = RunningMarker(url: directory.appendingPathComponent("running"))
let first = try marker.begin()
expect(!first, "first run is clean")
let second = try marker.begin()
expect(second, "leftover reports unclean run")
marker.finish()
let third = try marker.begin()
expect(!third, "normal termination consumes previous notice")
marker.finish()

let parent = ServerLifecycle.Identity.read(getpid())!
expect(parent.isCurrent, "current identity")
let stale = ServerLifecycle.Identity(pid: parent.pid, path: parent.path, seconds: parent.seconds + 1,
                                     microseconds: parent.microseconds)
expect(!stale.isCurrent, "PID reuse does not match")
let differentPath = ServerLifecycle.Identity(pid: parent.pid, path: "/invalid", seconds: parent.seconds,
                                             microseconds: parent.microseconds)
expect(!differentPath.isCurrent, "different executable does not match")
expect(!ServerLifecycle.stop(.init(parent: stale, server: stale)), "stale identity is never signalled")

func sleeper() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    return process
}
let child = try sleeper()
defer { if child.isRunning { child.terminate() } }
let childID = ServerLifecycle.Identity.read(child.processIdentifier)!
let recordURL = directory.appendingPathComponent("server.json")
try ServerLifecycle.save(.init(parent: parent, server: childID), at: recordURL)
expect(ServerLifecycle.cleanOrphans(in: directory) == 0, "live parent's server stays alive")
expect(child.isRunning, "live server untouched")
try ServerLifecycle.save(.init(parent: stale, server: childID), at: recordURL)
expect(ServerLifecycle.cleanOrphans(in: directory) == 1, "orphan removed")
child.waitUntilExit()
expect(!child.isRunning, "recorded orphan exits")
expect(ServerLifecycle.cleanOrphans(in: directory) == 0, "cleanup once")
// Kill only the fixture parent we just spawned. EOF must stop its recorded child.
let fixture = Process()
fixture.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let helper = ProcessInfo.processInfo.environment["KOE_LIFETIME_HELPER"] ?? fixture.executableURL!.path
fixture.arguments = ["--fixture-parent", directory.path, helper]
let fixtureInput = Pipe()
fixture.standardInput = fixtureInput
try fixture.run()
defer { if fixture.isRunning { fixture.terminate() } }
let ready = directory.appendingPathComponent("ready")
for _ in 0..<100 {
    if FileManager.default.fileExists(atPath: ready.path) { break }
    Thread.sleep(forTimeInterval: 0.05)
}
expect(FileManager.default.fileExists(atPath: ready.path), "fixture ready")
let fixtureURL = directory.appendingPathComponent("fixture.json")
let fixtureRecord = ServerLifecycle.read(fixtureURL)!
defer { ServerLifecycle.stop(fixtureRecord) }
expect(kill(fixture.processIdentifier, SIGKILL) == 0, "kill only fixture parent")
fixture.waitUntilExit()
for _ in 0..<100 {
    if !fixtureRecord.server.isCurrent && !FileManager.default.fileExists(atPath: fixtureURL.path) { break }
    Thread.sleep(forTimeInterval: 0.05)
}
expect(!fixtureRecord.server.isCurrent, "parent SIGKILL stops server within five seconds")
expect(!FileManager.default.fileExists(atPath: fixtureURL.path), "watchdog removes its ownership record")
// Explicit pipe closure follows the same cleanup path on an ordinary quit.
try? FileManager.default.removeItem(at: ready)
let normal = Process()
normal.executableURL = fixture.executableURL
normal.arguments = fixture.arguments
let normalInput = Pipe()
normal.standardInput = normalInput
try normal.run()
defer { if normal.isRunning { normal.terminate() } }
for _ in 0..<100 {
    if FileManager.default.fileExists(atPath: ready.path) { break }
    Thread.sleep(forTimeInterval: 0.05)
}
expect(FileManager.default.fileExists(atPath: ready.path), "normal fixture ready")
let normalRecord = ServerLifecycle.read(fixtureURL)!
defer { ServerLifecycle.stop(normalRecord) }
normalInput.fileHandleForWriting.closeFile()
for _ in 0..<100 {
    if !normal.isRunning { break }
    Thread.sleep(forTimeInterval: 0.05)
}
expect(!normal.isRunning && !normalRecord.server.isCurrent, "normal EOF stops server and helper")
expect(!FileManager.default.fileExists(atPath: fixtureURL.path), "normal cleanup removes record")
print("server lifecycle tests passed")
