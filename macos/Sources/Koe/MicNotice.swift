import CoreAudio
import Foundation
import IOKit

// マイクの注意（U-11）
// - AirPods など Bluetooth のマイク: 音が電話並みに粗くなり（通話用の方式に切り替わる）、語の取りこぼしが増える。メニューで ⚠ と「内蔵マイク推奨」を出す
// - 蓋を閉じた MacBook の内蔵マイク: 本体側でマイクが切られ、無音しか来ない。予備のマイクの候補から外し、
//   それで録れなかったら（無音だったら）理由を言い分けて知らせる
// 判定は transport（CoreAudio のデバイスの種類）と蓋の状態だけで行い、許可は要らない
enum MicNotice {
    enum Kind: String {
        case bluetooth
        case lidClosedBuiltIn = "lid_closed_builtin"
    }

    static func isBluetooth(_ transport: UInt32) -> Bool {
        transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    static func kind(transport: UInt32, lidClosed: Bool) -> Kind? {
        if transport == kAudioDeviceTransportTypeBuiltIn && lidClosed { return .lidClosedBuiltIn }
        if isBluetooth(transport) { return .bluetooth }
        return nil
    }

    // メニューの「マイク: …」の行の後ろに付ける
    static func lineSuffix(_ k: Kind?) -> String {
        switch k {
        case .bluetooth: return "  ⚠ 内蔵マイク推奨"
        case .lidClosedBuiltIn: return "  ⚠ 蓋が閉じています"
        case nil: return ""
        }
    }

    // マイクの一覧（サブメニュー）で、デバイス名の後ろに付ける
    static func itemSuffix(transport: UInt32, lidClosed: Bool) -> String {
        switch kind(transport: transport, lidClosed: lidClosed) {
        case .bluetooth: return "  ⚠ Bluetooth（音が粗くなります）"
        case .lidClosedBuiltIn: return "  ⚠ 蓋が閉じていると音を拾いません"
        case nil: return ""
        }
    }

    // サブメニューの先頭に出す説明（注意が無ければ nil）
    static func menuHint(_ k: Kind?) -> String? {
        switch k {
        case .bluetooth: return "⚠ Bluetooth のマイクは音が粗く、聞き取りが落ちます。内蔵マイク推奨"
        case .lidClosedBuiltIn: return "⚠ 蓋を閉じていると内蔵マイクは音を拾いません。外付けのマイクを選んでください"
        case nil: return nil
        }
    }

    // マイクから無音しか来なかったときの知らせ（蓋を閉じた内蔵マイクのときだけ、理由を言い分ける）
    static func silentMessage(_ k: Kind?) -> String? {
        guard k == .lidClosedBuiltIn else { return nil }
        return "蓋を閉じているので内蔵マイクは音を拾いません。外付けのマイクをつなぐか、蓋を開けてください"
    }

    // 予備のマイクの候補から外すマイク（蓋を閉じているときの内蔵マイク）
    static func dead(_ devices: [(id: AudioDeviceID, transport: UInt32)], lidClosed: Bool) -> Set<AudioDeviceID> {
        guard lidClosed else { return [] }
        return Set(devices.filter { $0.transport == kAudioDeviceTransportTypeBuiltIn }.map(\.id))
    }

    // 蓋が閉じているか。蓋の無い Mac（mini・iMac 等）や読めないときは false
    static func lidClosed() -> Bool {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        let v = IORegistryEntryCreateCFProperty(svc, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }
}
