// test-sources: OwnServer.swift
// make test: unit tests for Sources/Koe/OwnServer.swift (runs without XCTest)
import Darwin
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

typealias L = OwnServer.Listener

// holds: only 127.0.0.1 on the same port
check(OwnServer.holds([L(address: "127.0.0.1", port: 40001)], port: 40001), "holds the port")
check(!OwnServer.holds([L(address: "127.0.0.1", port: 40002)], port: 40001), "another port")
check(!OwnServer.holds([L(address: "0.0.0.0", port: 40001)], port: 40001), "wildcard address is not ours")
check(!OwnServer.holds([], port: 40001), "no listeners")

// isUp: all three conditions
check(OwnServer.isUp(running: true, holdsPort: true, healthStatus: 200), "up")
check(!OwnServer.isUp(running: false, holdsPort: true, healthStatus: 200), "child exited")
check(!OwnServer.isUp(running: true, holdsPort: false, healthStatus: 200), "port held by someone else")
check(!OwnServer.isUp(running: true, holdsPort: true, healthStatus: 503), "still loading")
check(!OwnServer.isUp(running: true, holdsPort: true, healthStatus: nil), "no answer")

// freeLoopbackPort: a usable, changing port
let p1 = OwnServer.freeLoopbackPort()
check(p1 != nil && p1! > 0 && p1! < 65536, "free port \(String(describing: p1))")

// listeners(pid:): sees a socket this process listens on, and not one it does not
func listen(port: Int) -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = UInt16(port).bigEndian
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    Darwin.listen(fd, 1)
    return fd
}
if let port = OwnServer.freeLoopbackPort() {
    check(!OwnServer.holds(OwnServer.listeners(pid: getpid()), port: port), "not listening yet")
    let fd = listen(port: port)
    check(OwnServer.holds(OwnServer.listeners(pid: getpid()), port: port), "own listener found: \(OwnServer.listeners(pid: getpid()))")
    // a child process that does not listen does not hold it
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["5"]
    try? child.run()
    check(!OwnServer.holds(OwnServer.listeners(pid: child.processIdentifier), port: port), "other process does not hold the port")
    child.terminate()
    close(fd)
    check(!OwnServer.holds(OwnServer.listeners(pid: getpid()), port: port), "closed listener is gone")
}
check(OwnServer.listeners(pid: 999_999).isEmpty, "unknown pid")

// removingControls: newlines kept, tabs to spaces, other controls dropped
check(TranscriptText.removingControls("a\nb") == "a\nb", "newline kept")
check(TranscriptText.removingControls("a\tb") == "a b", "tab to space")
check(TranscriptText.removingControls("a\u{1B}[2Jb\u{07}\r") == "a[2Jb", "controls dropped")
check(TranscriptText.removingControls("x\u{202E}y\u{2066}z") == "xyz", "bidi overrides dropped")
check(TranscriptText.removingControls("今日は👨‍👩‍👧、いい天気") == "今日は👨‍👩‍👧、いい天気", "ordinary text unchanged")
check(TranscriptText.removingControls("") == "", "empty")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("ownserver: ok")
