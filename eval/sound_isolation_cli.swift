// Applies Apple's AUSoundIsolation effect (the voice-isolation DSP available as an audio unit)
// to WAV files offline: AVAudioEngine in manual rendering mode, no microphone or speaker.
// Usage: sound_isolation_cli <in.wav> <out.wav> [<in.wav> <out.wav> ...]
//        sound_isolation_cli --params   (prints the unit's parameters and exits)
// The input is processed at its own sample rate (eval/voice_isolation_bench.py passes 48 kHz mono
// float WAV); the output has the same format. Used by #197 only; Koe itself does not use this.
import AVFoundation
import AudioToolbox

let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766f6973, // 'vois'
                                     componentManufacturer: kAudioUnitManufacturer_Apple,
                                     componentFlags: 0, componentFlagsMask: 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func process(_ input: URL, _ output: URL) throws {
    let file = try AVAudioFile(forReading: input)
    let format = file.processingFormat
    let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    let effect = AVAudioUnitEffect(audioComponentDescription: desc)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    engine.attach(player)
    engine.attach(effect)
    engine.connect(player, to: effect, format: format)
    engine.connect(effect, to: engine.mainMixerNode, format: format)
    try engine.start()
    player.scheduleFile(file, at: nil)
    player.play()
    let out = try AVAudioFile(forWriting: output, settings: file.fileFormat.settings,
                              commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    let total = file.length
    while engine.manualRenderingSampleTime < total {
        let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
        guard try engine.renderOffline(frames, to: buffer) == .success else { fail("render failed: \(input.lastPathComponent)") }
        try out.write(from: buffer)
    }
    player.stop()
    engine.stop()
}

let args = Array(CommandLine.arguments.dropFirst())
if args == ["--params"] {
    let engine = AVAudioEngine()
    let effect = AVAudioUnitEffect(audioComponentDescription: desc)
    engine.attach(effect)
    for p in effect.auAudioUnit.parameterTree?.allParameters ?? [] {
        print("\(p.identifier)\t\(p.displayName)\tvalue=\(p.value)\tmin=\(p.minValue)\tmax=\(p.maxValue)")
    }
    exit(0)
}
guard !args.isEmpty, args.count % 2 == 0 else { fail("usage: sound_isolation_cli <in.wav> <out.wav> ...") }
for i in stride(from: 0, to: args.count, by: 2) {
    do { try process(URL(fileURLWithPath: args[i]), URL(fileURLWithPath: args[i + 1])) } catch { fail("\(args[i]): \(error)") }
}
