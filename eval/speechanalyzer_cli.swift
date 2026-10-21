// A resident helper for eval/asr_bench.py (#180): reads one line per utterance on
// stdin, transcribes it on the Mac with Apple's SpeechAnalyzer (ja_JP, on-device),
// and prints one JSON line {"text": ..., "seconds": ...}.
//
// Line: the WAV path, optionally followed by tab-separated vocabulary hints that are
// passed as AnalysisContext.contextualStrings[.general]. The first argument picks the
// module: "speech" (SpeechTranscriber, the default) or "dictation" (DictationTranscriber).
import AVFoundation
import Foundation
import Speech

let useDictation = CommandLine.arguments.dropFirst().first == "dictation"
let locale = Locale(identifier: "ja_JP")

func transcribe<S: AsyncSequence>(_ module: any SpeechModule, _ results: S, text: @escaping (S.Element) -> AttributedString,
                                  url: URL, hints: [String]) async throws -> String {
    let analyzer = SpeechAnalyzer(modules: [module])
    if !hints.isEmpty {
        let context = AnalysisContext()
        context.contextualStrings[.general] = hints
        try await analyzer.setContext(context)
    }
    let file = try AVAudioFile(forReading: url)
    async let collected: String = results.reduce(into: "") { acc, r in acc += String(text(r).characters) }
    if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collected
}

func transcribe(_ url: URL, hints: [String]) async throws -> String {
    if useDictation {
        let t = DictationTranscriber(locale: locale, preset: .shortDictation)
        return try await transcribe(t, t.results, text: { $0.text }, url: url, hints: hints)
    }
    let t = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    return try await transcribe(t, t.results, text: { $0.text }, url: url, hints: hints)
}

let done = DispatchSemaphore(value: 0)
Task {
    while let line = readLine() {
        let fields = line.components(separatedBy: "\t")
        let url = URL(fileURLWithPath: fields[0].trimmingCharacters(in: .whitespaces))
        let hints = fields.dropFirst().filter { !$0.isEmpty }
        let start = Date()
        var text = ""
        do { text = try await transcribe(url, hints: Array(hints)) } catch {
            text = ""
            FileHandle.standardError.write(Data("speechanalyzer_cli: \(type(of: error))\n".utf8))
        }
        let out: [String: Any] = ["text": text, "seconds": Date().timeIntervalSince(start)]
        guard let data = try? JSONSerialization.data(withJSONObject: out) else { continue }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
    done.signal()
}
done.wait()
