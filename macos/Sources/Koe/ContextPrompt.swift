import Foundation

// Preserve explicit preferences while leaving previous-utterance context off by default.
enum ContextPrompt {
    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: "contextPrompt") as? Bool ?? false
    }
}
