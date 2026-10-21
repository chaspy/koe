import Foundation

// Shared by the app and the standalone command regression test.
enum LLM {
    static func command(_ cmd: String, prompt: String, timeout: Double, path: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", path.map { "export PATH=" + ImproveCommand.quote($0) + "; " + cmd } ?? cmd]
        if let path {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            p.environment = environment
        }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer { try? input.fileHandleForWriting.close() }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        } catch {
            if p.isRunning { p.terminate() }
            throw error
        }
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        var out = Data()
        let reader = DispatchQueue(label: "koe.llm.read")
        let sem = DispatchSemaphore(value: 0)
        reader.async { out = output.fileHandleForReading.readDataToEndOfFile(); sem.signal() }
        if sem.wait(timeout: .now() + max(1, deadline.timeIntervalSinceNow)) == .timedOut {
            p.terminate()
            throw NSError(domain: "Koe", code: 25, userInfo: [NSLocalizedDescriptionKey: "コマンドがタイムアウトしました: \(cmd)"])
        }
        p.waitUntilExit()
        let text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard p.terminationStatus == 0, !text.isEmpty else {
            throw NSError(domain: "KoeCommand", code: p.terminationStatus == 0 ? -1 : Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "コマンドが失敗しました（\(p.terminationStatus)）"])
        }
        return text
    }
}
