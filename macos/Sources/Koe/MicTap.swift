import AVFoundation
import Foundation
import KoeObjC

// Installing the recording tap on AVAudioEngine's input node (MicSource.start).
// `installTap(onBus:)` raises an Objective-C exception when the node's format is unusable
// (0 channels / 0 Hz): the input device vanished or changed between reading the format and
// installing the tap (a USB device re-enumerating, a Bluetooth profile switch, the default
// input changing). Swift cannot catch that, so Koe used to abort (SIGABRT) instead of
// recording a failed press. Two guards:
// 1. refuse a format with 0 channels or 0 Hz before touching the node;
// 2. install the tap inside an Objective-C @try/@catch (KoeObjC) so anything AVFAudio still
//    raises becomes a Failure the caller can log.
enum MicTap {
    enum Failure: String {
        case formatInvalid = "mic_format_invalid"   // 0 channels or 0 Hz
        case tapException = "mic_tap_exception"     // AVFAudio raised while installing the tap
        case engineStart = "engine_start_failed"    // AVAudioEngine.start() threw
    }

    static func isUsable(sampleRate: Double, channels: UInt32) -> Bool {
        sampleRate > 0 && channels > 0
    }

    static func isUsable(_ format: AVAudioFormat) -> Bool {
        isUsable(sampleRate: format.sampleRate, channels: format.channelCount)
    }

    // Returns nil when the tap is installed, otherwise why it was not. Never raises.
    @discardableResult
    static func install(on node: AVAudioNode, bus: AVAudioNodeBus = 0, bufferSize: AVAudioFrameCount,
                        format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) -> Failure? {
        guard isUsable(format) else { return .formatInvalid }
        let error = KoeCatchObjCException {
            node.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
        }
        return error == nil ? nil : .tapException
    }

    // What to tell the user when a press could not start recording for this reason
    static func message(_ f: Failure?) -> String {
        switch f {
        case .formatInvalid, .tapException:
            return "マイクの入力形式が取れませんでした。マイクを抜き差しした直後なら、もう一度押してください"
        case .engineStart, nil:
            return "録音を開始できませんでした（マイクの許可を確認してください）"
        }
    }
}
