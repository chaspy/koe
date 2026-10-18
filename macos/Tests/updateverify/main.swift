// test-sources: UpdateVerify.swift
// make test: unit tests for Sources/Koe/UpdateVerify.swift (runs without XCTest)
import Foundation
import Security

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

let fm = FileManager.default
func mkdir(_ url: URL) {
    do { try fm.createDirectory(at: url, withIntermediateDirectories: true) } catch { print("FAIL: mkdir \(error)"); exit(1) }
}
let work = fm.temporaryDirectory.appendingPathComponent("koe-updateverify-test-\(getpid())")
try? fm.removeItem(at: work)
mkdir(work)
defer { try? fm.removeItem(at: work) }

// The pinned requirement parses
var req: SecRequirement?
check(SecRequirementCreateWithString(UpdateVerify.requirement as CFString, [], &req) == errSecSuccess, "requirement parses")

// A bundle without a signature
let unsigned = work.appendingPathComponent("Unsigned.app/Contents/MacOS")
mkdir(unsigned)
fm.createFile(atPath: unsigned.appendingPathComponent("Unsigned").path, contents: Data("#!/bin/sh\n".utf8),
              attributes: [.posixPermissions: 0o755])
let plist = ["CFBundleExecutable": "Unsigned", "CFBundleIdentifier": "io.github.chaspy.koe"]
(plist as NSDictionary).write(to: work.appendingPathComponent("Unsigned.app/Contents/Info.plist"), atomically: true)
check(UpdateVerify.check(appAt: work.appendingPathComponent("Unsigned.app"))?.reason == "unsigned", "unsigned bundle is rejected")
check(UpdateVerify.check(appAt: work.appendingPathComponent("Missing.app")) != nil, "missing bundle is rejected")

// A validly signed app that is not Koe
let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
if fm.fileExists(atPath: calc.path) {
    check(UpdateVerify.check(appAt: calc)?.reason == "not_koe", "another developer's app is rejected: \(String(describing: UpdateVerify.check(appAt: calc)))")
    check(UpdateVerify.check(appAt: calc, requirement: #"anchor apple and identifier "com.apple.calculator""#) == nil, "signed app passes its own requirement")
}

// An ad-hoc signed bundle: valid, but not signed by Koe's developer; changed afterwards, it is invalid
func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}
let signed = work.appendingPathComponent("Signed.app")
_ = run("/usr/bin/ditto", [work.appendingPathComponent("Unsigned.app").path, signed.path])
mkdir(signed.appendingPathComponent("Contents/Resources"))
fm.createFile(atPath: signed.appendingPathComponent("Contents/Resources/note.txt").path, contents: Data("a".utf8))
check(run("/usr/bin/codesign", ["-s", "-", "--force", signed.path]) == 0, "ad-hoc signing for the test")
let own = #"identifier "io.github.chaspy.koe""#
check(UpdateVerify.check(appAt: signed, requirement: own) == nil, "signed bundle passes a matching requirement")
check(UpdateVerify.check(appAt: signed)?.reason == "not_koe", "ad-hoc signature does not satisfy the pinned requirement")
fm.createFile(atPath: signed.appendingPathComponent("Contents/Resources/note.txt").path, contents: Data("b".utf8))
check(UpdateVerify.check(appAt: signed, requirement: own)?.reason == "invalid", "changed after signing: \(String(describing: UpdateVerify.check(appAt: signed, requirement: own)))")

// Messages
check(UpdateVerify.failure(for: errSecSuccess) == nil, "success")
check(UpdateVerify.failure(for: errSecCSReqFailed)?.message == "Koe の開発元の署名ではありません", "not koe message")
check(UpdateVerify.failure(for: -1)?.message.contains("-1") == true, "other status message")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("updateverify: ok")
