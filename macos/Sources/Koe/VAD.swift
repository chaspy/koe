import CryptoKit
import Foundation

// Optional Silero VAD inside whisper-server (off by default):
//   defaults write io.github.chaspy.koe vad -bool true
// whisper.cpp runs Silero on the uploaded audio, keeps only the speech
// segments (each padded by `speechPadMs`) and transcribes nothing when it
// finds no speech. Koe keeps its own energy trim and the checks after
// transcription; an empty answer is handled like today's hallucination drop.
// Numbers: docs/notes/2026-10-18-vad-before-transcription.md.
//
// The model (0.9 MB, MIT) is downloaded once into Koe's models directory from
// a pinned Hugging Face revision and accepted only when its SHA-256 matches.
enum VAD {
    static let fileName = "ggml-silero-v5.1.2.bin"
    static let revision = "9ffd54a1e1ee413ddf265af9913beaf518d1639b"
    static let sha256 = "29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf"
    static let url = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/\(revision)/\(fileName)")!
    static let speechPadMs = 250

    static var enabled: Bool { UserDefaults.standard.object(forKey: "vad") as? Bool ?? false }

    static var modelPath: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/models/\(fileName)").path
    }

    // Set by WhisperServer when it launches the server with the model. A server that
    // was already running (started by another Koe) has no model, so no VAD is requested
    // from it: whisper-server answers 500 to `vad=true` without a model.
    static var serverHasModel = false

    // Arguments appended to whisper-server's command line
    static func serverArguments(enabled: Bool = enabled, modelPath: String = modelPath,
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        enabled && exists(modelPath) ? ["-vm", modelPath] : []
    }

    // Multipart fields appended to every /inference request
    static func requestFields(enabled: Bool = enabled, serverHasModel: Bool = serverHasModel) -> [(String, String)] {
        enabled && serverHasModel ? [("vad", "true"), ("vad_speech_pad_ms", String(speechPadMs))] : []
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(_ data: Data, expected: String = sha256) -> Bool {
        digest(data) == expected
    }

    // Downloads the model when the setting is on and the file is missing. Calls `done`
    // right away otherwise. A mismatching download is discarded and reported; whisper
    // then starts without VAD.
    static func prepare(done: @escaping (Result<Void, Error>) -> Void) {
        guard enabled, !FileManager.default.fileExists(atPath: modelPath) else { return done(.success(())) }
        let dest = URL(fileURLWithPath: modelPath)
        var req = URLRequest(url: url)
        req.timeoutInterval = 120
        URLSession.shared.downloadTask(with: req) { location, response, error in
            if let error { return done(.failure(error)) }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let location, let data = try? Data(contentsOf: location) else {
                return done(.failure(NSError(domain: "Koe", code: 40, userInfo: [
                    NSLocalizedDescriptionKey: "VAD モデルのダウンロードに失敗しました (HTTP \(code))"])))
            }
            guard verify(data) else {
                try? FileManager.default.removeItem(at: location)
                return done(.failure(NSError(domain: "Koe", code: 41, userInfo: [
                    NSLocalizedDescriptionKey: "VAD モデルの検証に失敗しました（SHA-256 が一致しません）"])))
            }
            do {
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                done(.success(()))
            } catch {
                done(.failure(error))
            }
        }.resume()
    }
}
