// test-sources: LLMCommand.swift ImproveCommand.swift
import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)
let prompt = String(repeating: "x", count: 128 * 1024)
var failures = 0
for _ in 0..<20 {
    do {
        _ = try LLM.command("exit 127", prompt: prompt, timeout: 5)
        fatalError("An immediately failing command must throw")
    } catch {
        failures += 1
    }
}
precondition(failures == 20)
let result = try LLM.command("cat", prompt: "synthetic-input", timeout: 5)
precondition(result == "synthetic-input")
print("llmcommand: 20/20 early exits reported as failures; successful command passed")
