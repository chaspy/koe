// 単体テストの共通部品。使うテストは test-sources に ../../Tests/TestSupport.swift を足す
// （scripts/test.sh は Tests/ の下のフォルダだけをテストとして拾うので、このファイルはテストにならない）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}
