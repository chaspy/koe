// test-sources: MicTap.swift ../KoeObjC/KoeObjC.m
// make test: Sources/Koe/MicTap.swift の単体テスト（XCTest なしで動く）
// #156: installTap(onBus:) が 0 ch / 0 Hz の形式で NSException を投げて Koe ごと落ちていた
import AVFoundation
import Foundation
import KoeObjC

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

// 形式の判定
check(MicTap.isUsable(sampleRate: 48000, channels: 1), "48 kHz mono は使える")
check(MicTap.isUsable(sampleRate: 16000, channels: 2), "16 kHz stereo は使える")
check(!MicTap.isUsable(sampleRate: 0, channels: 1), "0 Hz は使えない")
check(!MicTap.isUsable(sampleRate: 48000, channels: 0), "0 ch は使えない")
check(!MicTap.isUsable(sampleRate: 0, channels: 0), "0 Hz / 0 ch は使えない")

// ObjC 例外が Swift の値になる（abort しない）
let caught = KoeCatchObjCException { NSException(name: .genericException, reason: "boom", userInfo: nil).raise() }
check(caught != nil, "raise した NSException が NSError として返る")
check(caught?.localizedDescription.contains("boom") == true, "理由が入る: \(caught?.localizedDescription ?? "nil")")
check(KoeCatchObjCException {} == nil, "例外が無ければ nil")

// engine に繋がっていないノードへの tap は AVFAudio が例外を投げる（NULL != engine）。落ちずに tapException になる
let detached = AVAudioMixerNode()
if let f = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) {
    check(MicTap.install(on: detached, bufferSize: 1024, format: f) { _, _ in } == .tapException, "engine 無しのノードは tapException")
}

// 0 Hz の形式は node に触る前に formatInvalid（クラッシュの形式そのもの）
if let zero = AVAudioFormat(standardFormatWithSampleRate: 0, channels: 1) {
    check(MicTap.install(on: detached, bufferSize: 1024, format: zero) { _, _ in } == .formatInvalid, "0 Hz は formatInvalid")
    // 判定を外して本物の入力ノードに入れても、例外は捕まえて返る（マイクの許可は要らない: tap を入れる前に落ちる）
    let engine = AVAudioEngine()
    let err = KoeCatchObjCException { engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: zero) { _, _ in } }
    check(err?.localizedDescription.contains("IsFormatSampleRateAndChannelCountValid") == true,
          "入力ノードに 0 Hz を入れた例外が捕まる: \(err?.localizedDescription ?? "nil")")
}

// 文言: 形式の問題は抜き差しを案内、それ以外は従来どおり許可を案内
check(MicTap.message(.formatInvalid).contains("抜き差し"), "formatInvalid の文言")
check(MicTap.message(.tapException).contains("抜き差し"), "tapException の文言")
check(MicTap.message(nil).contains("許可"), "nil の文言")
check(MicTap.message(.engineStart).contains("許可"), "engineStart の文言")

if failures == 0 { print("mictap: ok") } else { print("mictap: \(failures) failed"); exit(1) }
