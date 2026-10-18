// test-sources: MicNotice.swift
// make test: Sources/Koe/MicNotice.swift の単体テスト（XCTest なしで動く）
import CoreAudio
import Foundation

var failures = 0
func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
    if !ok { failures += 1; print("FAIL: \(msg())") }
}

let bt = kAudioDeviceTransportTypeBluetooth
let ble = kAudioDeviceTransportTypeBluetoothLE
let builtIn = kAudioDeviceTransportTypeBuiltIn
let usb = kAudioDeviceTransportTypeUSB
let virt = kAudioDeviceTransportTypeVirtual

// 種類の判定
for (t, lid, want) in [
    (bt, false, MicNotice.Kind.bluetooth), (bt, true, .bluetooth), (ble, false, .bluetooth),
    (builtIn, true, .lidClosedBuiltIn),
] as [(UInt32, Bool, MicNotice.Kind)] {
    check(MicNotice.kind(transport: t, lidClosed: lid) == want, "kind(\(t), lid \(lid)) = \(String(describing: MicNotice.kind(transport: t, lidClosed: lid))), want \(want)")
}
for (t, lid) in [(builtIn, false), (usb, false), (usb, true), (virt, true), (UInt32(0), true)] as [(UInt32, Bool)] {
    check(MicNotice.kind(transport: t, lidClosed: lid) == nil, "kind(\(t), lid \(lid)) は注意なし")
}

// 表示: Bluetooth は ⚠ と「内蔵マイク推奨」
check(MicNotice.lineSuffix(.bluetooth).contains("⚠") && MicNotice.lineSuffix(.bluetooth).contains("内蔵マイク推奨"), "Bluetooth の行")
check(MicNotice.menuHint(.bluetooth)?.contains("内蔵マイク推奨") == true, "Bluetooth のヒント")
check(MicNotice.lineSuffix(.lidClosedBuiltIn).contains("蓋"), "蓋の行")
check(MicNotice.lineSuffix(nil).isEmpty && MicNotice.menuHint(nil) == nil, "注意なしは何も出さない")
check(MicNotice.itemSuffix(transport: usb, lidClosed: true).isEmpty, "USB のマイクには何も付けない")
check(MicNotice.itemSuffix(transport: builtIn, lidClosed: false).isEmpty, "蓋が開いていれば内蔵マイクに何も付けない")
check(MicNotice.itemSuffix(transport: builtIn, lidClosed: true).contains("蓋"), "蓋を閉じた内蔵マイク")
check(MicNotice.itemSuffix(transport: ble, lidClosed: false).contains("Bluetooth"), "BLE のマイク")

// 無音のときの知らせは、蓋を閉じた内蔵マイクのときだけ言い分ける
check(MicNotice.silentMessage(.lidClosedBuiltIn)?.contains("蓋") == true, "蓋の無音")
check(MicNotice.silentMessage(.bluetooth) == nil && MicNotice.silentMessage(nil) == nil, "それ以外はいつもの文")

// 予備のマイクから外すのは、蓋を閉じているときの内蔵マイクだけ
let devs: [(id: AudioDeviceID, transport: UInt32)] = [(1, builtIn), (2, usb), (3, bt), (4, virt)]
check(MicNotice.dead(devs, lidClosed: true) == [1], "蓋を閉じている: \(MicNotice.dead(devs, lidClosed: true))")
check(MicNotice.dead(devs, lidClosed: false).isEmpty, "蓋が開いている")

// 蓋の状態は読めても読めなくても落ちない
_ = MicNotice.lidClosed()

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("micnotice: ok")
