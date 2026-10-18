// test-sources: VAD.swift
// make test: Sources/Koe/VAD.swift の単体テスト（XCTest なしで動く）
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// SHA-256（既知の値）
check(VAD.digest(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "digest(empty)")
check(VAD.digest("abc".data(using: .utf8)!) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "digest(abc)")
check(VAD.verify(Data(), expected: VAD.digest(Data())), "verify matches")
check(!VAD.verify("x".data(using: .utf8)!), "verify rejects other data against the pinned model hash")
check(VAD.sha256.count == 64, "pinned hash length")
check(VAD.url.absoluteString.contains(VAD.revision) && VAD.url.absoluteString.hasSuffix(VAD.fileName), "pinned URL")

// キャッシュ済みモデルの検証: 一致すれば残す、不一致なら消す、無ければ false
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("koe-vad-test-\(getpid()).bin").path
let good = "abc".data(using: .utf8)!
FileManager.default.createFile(atPath: tmp, contents: good)
check(VAD.validateCached(at: tmp, expected: VAD.digest(good)), "cached model with matching hash is kept")
check(FileManager.default.fileExists(atPath: tmp), "matching file still exists")
check(!VAD.validateCached(at: tmp, expected: VAD.sha256), "cached model with another hash is rejected")
check(!FileManager.default.fileExists(atPath: tmp), "mismatching file is deleted")
check(!VAD.validateCached(at: tmp, expected: VAD.sha256), "missing file is not valid")

// サーバーの引数: 設定オン かつ モデルあり のときだけ
check(VAD.serverArguments(enabled: true, modelPath: "/m.bin", exists: { _ in true }) == ["-vm", "/m.bin"], "args on")
check(VAD.serverArguments(enabled: true, modelPath: "/m.bin", exists: { _ in false }).isEmpty, "args without model")
check(VAD.serverArguments(enabled: false, modelPath: "/m.bin", exists: { _ in true }).isEmpty, "args off")

// 要求のフィールド: 設定オン かつ 自分がモデル付きで起こしたサーバー のときだけ
let on = VAD.requestFields(enabled: true, serverHasModel: true)
check(on.map(\.0) == ["vad", "vad_speech_pad_ms"] && on.map(\.1) == ["true", "250"], "fields on: \(on)")
check(VAD.requestFields(enabled: true, serverHasModel: false).isEmpty, "fields with a server that has no model")
check(VAD.requestFields(enabled: false, serverHasModel: true).isEmpty, "fields off")

// 既定はオフ
check(VAD.requestFields(enabled: VAD.enabled, serverHasModel: true).isEmpty || UserDefaults.standard.object(forKey: "vad") != nil, "default off")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("vad: ok")
