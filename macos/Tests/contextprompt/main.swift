// test-sources: ContextPrompt.swift ../../Tests/TestSupport.swift
import Foundation

let suite = "org.example.koe.context-test.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suite) else { exit(1) }
defer { defaults.removePersistentDomain(forName: suite) }
check(!ContextPrompt.enabled(in: defaults), "unset defaults to off")
defaults.set(true, forKey: "contextPrompt")
check(ContextPrompt.enabled(in: defaults), "explicit true is preserved")
defaults.set(false, forKey: "contextPrompt")
check(!ContextPrompt.enabled(in: defaults), "explicit false is preserved")
if failures > 0 { exit(1) }
print("contextprompt: ok")
