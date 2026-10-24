// Usage: whisperkit_cli <model folder>
// Reads one line per request on stdin: "<wav path>" or "<wav path>\t<prompt>", and prints
// {"text": ..., "seconds": ...} per line. Japanese, temperature 0 without fallback, the prompt (when
// given) as prompt tokens like whisper.cpp's initial prompt. Only the transcription is timed.
import Foundation
import WhisperKit

@main
struct Main {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: whisperkit_cli <model folder>\n".utf8))
            exit(2)
        }
        let config = WhisperKitConfig(modelFolder: CommandLine.arguments[1], verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        let kit = try await WhisperKit(config)
        while let line = readLine() {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            var options = DecodingOptions(task: .transcribe, language: "ja", temperature: 0,
                                          temperatureFallbackCount: 0, usePrefillPrompt: true,
                                          skipSpecialTokens: true, withoutTimestamps: true)
            if parts.count > 1, let tokenizer = kit.tokenizer {
                options.promptTokens = tokenizer.encode(text: " " + parts[1])
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            }
            let started = Date()
            let results = try await kit.transcribe(audioPath: parts[0], decodeOptions: options)
            let text = results.map(\.text).joined()
            let out: [String: Any] = ["text": text, "seconds": Date().timeIntervalSince(started)]
            let data = try JSONSerialization.data(withJSONObject: out)
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}
