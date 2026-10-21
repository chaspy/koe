import AppKit
import AudioToolbox
import CoreAudio
import Foundation

// 録音中は音楽・動画の音を小さくする（U-10）。
//
// 方式: 録音中だけ、出力の音量（システムの音量）を下げ、録音が終わったら元に戻す。
// 本当は「鳴っている音楽・動画だけを一時停止」したかったが、macOS 15.4 以降、何が再生中かを知る仕組み（MediaRemote）は
// Apple 以外のアプリから使えない（10/17 に macOS 26.5 で確認: Koe と同じ署名なしのプロセスからは何も再生していない扱いになり、
// Apple 署名の /usr/bin/perl の中からだけ再生中のアプリが見えた）。抜け道に頼らず、公開の CoreAudio だけで作る。
//
// - 何かのアプリが音を出しているときだけ下げる（CoreAudio のプロセス一覧。Koe 自身の開始音は数えない）
// - 会議アプリが音を出しているときは下げない（相手の声を小さくしない）
// - 押してから少し待って下げる（誤って短く触れたとき、音が一瞬下がらないように）
// - 録音中に本人が音量を変えたら、終わっても戻さない
// - 下げている途中で録音が終わったら、下げるのを止めて元の音量に戻す（途中の音量は本人が変えたものではない）
// - Koe を終了するときは、その場で元の音量に戻してから終わる
// - 途中で Koe が落ちても、次に起動したときに戻す（下げる前の音量を UserDefaults に残す）
// events には数字と理由だけを書く（どのアプリが鳴っていたかは書かない）
enum MediaDuck {
    static let ratio: Float32 = 0.25     // 元の音量の 1/4 まで下げる
    static let delay: TimeInterval = 0.25
    static let pendingKey = "duckPending"

    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.cisco.webexmeetingsapp", "Cisco-Systems.Spark",
        "com.apple.FaceTime", "com.hnc.Discord", "com.tinyspeck.slackmacgap", "com.skype.skype", "co.teamport.around",
        "com.amazon.Amazon-Chime", "com.google.meet",
    ]
    // Apple の部品のうち、音楽・動画を鳴らすもの（それ以外の com.apple.* は通知音などのシステムの音として数えない）
    static let appleMedia: Set<String> = [
        "com.apple.Music", "com.apple.TV", "com.apple.podcasts", "com.apple.QuickTimePlayerX", "com.apple.Safari",
        "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent", "com.apple.iTunes",
    ]

    enum Decision: Equatable { case duck, skip(String) }

    // 音を出しているアプリ（bundle ID。分からなければ空）から、下げるかを決める
    static func decide(outputting: [String]) -> Decision {
        if outputting.contains(where: { meetingApps.contains($0) || $0.hasPrefix("com.google.Chrome.app.") }) { return .skip("meeting") }
        let media = outputting.filter { !$0.hasPrefix("com.apple.") || appleMedia.contains($0) }
        return media.isEmpty ? .skip("silent") : .duck
    }

    // 戻す音量。録音中に本人が変えていたら（下げた値から 1 段以上動いていたら）戻さない。
    // 機器は音量を段階に丸める（0.13 を入れると 0.16 になる。1 段は約 1/16）ので、下げた後に読み直した値と比べる。
    // まだ下げている途中（settled でない）なら、今の音量は Koe が動かしている途中の値なので、必ず元に戻す
    static func restoreValue(original: Float32, ducked: Float32, now: Float32, settled: Bool = true) -> Float32? {
        guard settled else { return original }
        return abs(now - ducked) < 0.07 ? original : nil
    }

    // 音量の読み書き（テストでは偽物の機器に差し替える）
    struct Hardware {
        var defaultOutput: () -> AudioDeviceID? = { MediaDuck.defaultOutput() }
        var outputtingApps: () -> [String] = { MediaDuck.outputtingApps() }
        var volume: (AudioDeviceID) -> Float32? = { MediaDuck.volume($0) }
        var isSettable: (AudioDeviceID) -> Bool = { MediaDuck.isSettable($0) }
        var setVolume: (AudioDeviceID, Float32) -> Void = { MediaDuck.setVolume($0, $1) }
        var uid: (AudioDeviceID) -> String? = { MediaDuck.uid($0) }
        var device: (String) -> AudioDeviceID? = { MediaDuck.device(uid: $0) }
    }
    static var hw = Hardware()

    // MARK: - 録音から呼ぶ（Recorder）

    private static var pending: DispatchWorkItem?
    // 下げている（settled = 下げ終わった）。下げ終わるまでの音量の動きは Koe のもの
    private static var active: (device: AudioDeviceID, original: Float32, ducked: Float32, settled: Bool)?
    // 戻している途中（その間に次の録音が始まったら、途中の音量ではなく、戻す先を元の音量として使う）
    private static var restoringTo: (device: AudioDeviceID, volume: Float32)?

    static func recordingStarted() {
        guard Settings.duckMedia else { return }
        pending?.cancel()
        let w = DispatchWorkItem { duck() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    static func recordingEnded() {
        pending?.cancel()
        pending = nil
        restore()
    }

    // Koe の終了: 後で動く fade を待たず、その場で元の音量に戻してから、残しておいた元の音量を消す
    static func restoreNow() {
        pending?.cancel()
        pending = nil
        if active != nil {
            restore(immediately: true)
        } else if let r = restoringTo {
            fadeGen += 1
            hw.setVolume(r.device, r.volume)
            restoringTo = nil
            Settings.defaults.removeObject(forKey: pendingKey)
        }
    }

    // 起動時: 前回、下げたまま終わっていたら戻す
    static func restoreLeftover() {
        guard let p = Settings.defaults.dictionary(forKey: pendingKey),
              let uid = p["device"] as? String, let o = p["original"] as? Double, let d = p["ducked"] as? Double else { return }
        Settings.defaults.removeObject(forKey: pendingKey)
        guard let dev = hw.device(uid), let now = hw.volume(dev) else { return }
        // 下げている途中で落ちていたら、今の音量は Koe が動かしていた途中の値なので、必ず戻す
        let settled = p["settled"] as? Bool ?? true
        let v = restoreValue(original: Float32(o), ducked: Float32(d), now: now, settled: settled)
        if let v { hw.setVolume(dev, v) }
        Events.log("media_restored", ["after_restart": true, "restored": v != nil])
    }

    private static func duck() {
        pending = nil
        guard active == nil, let dev = hw.defaultOutput() else { return }
        if case .skip(let reason) = decide(outputting: hw.outputtingApps()) {
            if reason != "silent" { Events.log("media_duck_skipped", ["reason": reason]) }
            return
        }
        guard let current = hw.volume(dev), hw.isSettable(dev) else { return Events.log("media_duck_skipped", ["reason": "no_volume"]) }
        // 前の録音の音量を戻している途中なら、戻す先が本当の元の音量
        let original = restoringTo?.device == dev ? restoringTo!.volume : current
        restoringTo = nil
        guard original > 0.04 else { return }
        let target = original * ratio
        active = (dev, original, target, false)
        func remember(_ d: Float32, settled: Bool) {
            if let uid = hw.uid(dev) {
                Settings.defaults.set(["device": uid, "original": Double(original), "ducked": Double(d), "settled": settled], forKey: pendingKey)
            }
        }
        remember(target, settled: false)
        fade(dev, from: current, to: target) {
            // 機器が丸めた後の値を、戻すときの比べる相手にする
            guard let a = active, a.device == dev, let v = hw.volume(dev) else { return }
            active = (dev, original, v, true)
            remember(v, settled: true)
            Events.log("media_ducked", ["from": round(Double(original) * 100) / 100, "to": round(Double(v) * 100) / 100])
        }
    }

    private static func restore(immediately: Bool = false) {
        guard let a = active else { return }
        active = nil
        fadeGen += 1   // 下げている途中なら、残りの段を止める（止めないと 1/4 まで下がりきって残る）
        guard let now = hw.volume(a.device) else { return Settings.defaults.removeObject(forKey: pendingKey) }
        guard let v = restoreValue(original: a.original, ducked: a.ducked, now: now, settled: a.settled) else {
            Settings.defaults.removeObject(forKey: pendingKey)
            return Events.log("media_restored", ["restored": false, "reason": "changed_by_user"])
        }
        Events.log("media_restored", ["restored": true, "while_ducking": !a.settled])
        if immediately {
            hw.setVolume(a.device, v)
            Settings.defaults.removeObject(forKey: pendingKey)
            return
        }
        // 戻し終わるまでは、残しておいた元の音量を消さない（その間に落ちても、次の起動で戻せる）
        restoringTo = (a.device, v)
        fade(a.device, from: now, to: v) {
            restoringTo = nil
            Settings.defaults.removeObject(forKey: pendingKey)
        }
    }

    // 0.15 秒かけて変える（いきなり変わると驚く）
    // 新しく変え始めたら、前の変更の残りの段は捨てる（下げている途中で録音が終わったとき）
    private static var fadeGen = 0
    private static func fade(_ dev: AudioDeviceID, from: Float32, to: Float32, done: (() -> Void)? = nil) {
        let steps = 6
        fadeGen += 1
        let gen = fadeGen
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025 * Double(i)) {
                guard gen == fadeGen else { return }
                hw.setVolume(dev, from + (to - from) * Float32(i) / Float32(steps))
                if i == steps { done?() }
            }
        }
    }

    // MARK: - CoreAudio

    private static func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    fileprivate static func defaultOutput() -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id) == noErr && id != 0 ? id : nil
    }

    fileprivate static func volume(_ dev: AudioDeviceID) -> Float32? {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var v = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectHasProperty(dev, &a) && AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &v) == noErr ? v : nil
    }

    fileprivate static func isSettable(_ dev: AudioDeviceID) -> Bool {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &a, &ok) == noErr && ok.boolValue
    }

    fileprivate static func setVolume(_ dev: AudioDeviceID, _ v: Float32) {
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var x = max(0, min(1, v))
        AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
    }

    fileprivate static func uid(_ dev: AudioDeviceID) -> String? {
        var a = addr(kAudioDevicePropertyDeviceUID)
        var s: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &s) == noErr, let s else { return nil }
        return s.takeRetainedValue() as String
    }

    fileprivate static func device(uid: String) -> AudioDeviceID? {
        var a = addr(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString, id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let st = withUnsafePointer(to: &cf) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return st == noErr && id != 0 ? id : nil
    }

    // 音を出しているプロセスの bundle ID（Koe 自身は除く）。一覧が取れない OS では、出力が動いていれば「分からないアプリ」1 つとして扱う
    fileprivate static func outputtingApps() -> [String] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size) == noErr, size > 0 else {
            var r = addr(kAudioDevicePropertyDeviceIsRunningSomewhere)
            var running: UInt32 = 0, s = UInt32(4)
            guard let dev = defaultOutput(), AudioObjectGetPropertyData(dev, &r, 0, nil, &s, &running) == noErr else { return [] }
            return running != 0 ? [""] : []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &ids) == noErr else { return [] }
        let me = getpid()
        return ids.compactMap { p in
            var r = addr(kAudioProcessPropertyIsRunningOutput)
            var running: UInt32 = 0, s = UInt32(4)
            guard AudioObjectGetPropertyData(p, &r, 0, nil, &s, &running) == noErr, running != 0 else { return nil }
            var pa = addr(kAudioProcessPropertyPID)
            var pid: pid_t = 0, ps = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(p, &pa, 0, nil, &ps, &pid) == noErr, pid == me { return nil }
            var ba = addr(kAudioProcessPropertyBundleID)
            var b: Unmanaged<CFString>?, bs = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(p, &ba, 0, nil, &bs, &b) == noErr, let b else { return "" }
            return b.takeRetainedValue() as String
        }
    }
}

// メニューの「録音中は音楽・動画の音を小さくする」（既定オフ。Settings.duckMedia）

final class MediaDuckMenu: NSObject {
    static let shared = MediaDuckMenu()
    lazy var item: NSMenuItem = {
        let i = NSMenuItem(title: "録音中は音楽・動画の音を小さくする", action: #selector(toggle), keyEquivalent: "")
        i.target = self
        i.toolTip = "音楽や動画を流しながら話しても、その音を拾わないように、話している間だけ Mac の音量を下げて、話し終えたら戻します。会議アプリの音が出ているときは下げません"
        i.state = Settings.duckMedia ? .on : .off
        return i
    }()

    @objc private func toggle() {
        Settings.duckMedia.toggle()
        item.state = Settings.duckMedia ? .on : .off
        if !Settings.duckMedia { MediaDuck.recordingEnded() }
        Events.log("duck_media_changed", ["on": Settings.duckMedia])
    }
}
