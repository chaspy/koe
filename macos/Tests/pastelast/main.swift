// test-sources: PasteLast.swift ../../Tests/TestSupport.swift
// make test: Sources/Koe/PasteLast.swift の単体テスト（XCTest なしで動く）
import CoreGraphics
import Foundation

// PasteLast.swift が使う main.swift の部品の代わり
enum Settings { static var pasteLast = true }
enum Events { static func log(_ type: String, _ extra: [String: Any] = [:]) {} }

let t0 = Date(timeIntervalSince1970: 0)
check(PasteLast.pick([]) == nil, "empty")
check(PasteLast.pick([(t0, "一つ目"), (t0.addingTimeInterval(5), "二つ目")])?.text == "二つ目", "newest wins")
check(PasteLast.pick([(t0, "一つ目"), (t0.addingTimeInterval(5), "  \n")])?.text == "一つ目", "skip blank")
check(PasteLast.pick([(t0, " ")]) == nil, "only blank")

// ⌃⌥ が離されるまで待つ
check(PasteLast.holdsHotkeyModifiers([.maskControl, .maskAlternate]), "ctrl+opt held")
check(PasteLast.holdsHotkeyModifiers(.maskAlternate), "opt held")
check(!PasteLast.holdsHotkeyModifiers([]), "none")
check(!PasteLast.holdsHotkeyModifiers([.maskCommand, .maskShift]), "cmd/shift do not count")

func run(_ flags: @escaping () -> CGEventFlags, maxWait: TimeInterval) -> (TimeInterval, Bool)? {
    var got: (TimeInterval, Bool)?
    PasteLast.whenModifiersReleased(maxWait: maxWait, poll: 0.01, flags: flags) { got = ($0, $1) }
    let until = Date().addingTimeInterval(2)
    while got == nil && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    return got
}
// 押していなければすぐ貼る
if let r = run({ [] }, maxWait: 1) { check(r.1 && r.0 < 0.05, "immediate \(r)") } else { check(false, "immediate: no call") }
// 0.1 秒後に離す → 離されてから貼る
let releaseAt = Date().addingTimeInterval(0.1)
if let r = run({ Date() < releaseAt ? [.maskControl, .maskAlternate] : [] }, maxWait: 1) {
    check(r.1 && r.0 >= 0.09 && r.0 < 0.5, "after release \(r)")
} else { check(false, "after release: no call") }
// 離されないまま → maxWait で諦めて貼る（1 回だけ）
var calls = 0
PasteLast.whenModifiersReleased(maxWait: 0.2, poll: 0.01, flags: { .maskControl }) { _, released in
    calls += 1
    check(!released, "timeout reports not released")
}
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
check(calls == 1, "timeout calls once: \(calls)")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("pastelast: ok")
