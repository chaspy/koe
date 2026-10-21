import Foundation

// Only explicit evidence determines the source; internal quits remain unknown.
enum QuitLog {
    static func source(menu: Bool, appleEvent: Bool, logout: Bool, system: Bool) -> String {
        if logout { return "logout" }
        if system { return "system" }
        if menu { return "menu" }
        if appleEvent { return "apple_event" }
        return "unknown"
    }

    static func previousQuitUnrecorded(state: String?, events: String) -> Bool {
        guard state?.trimmingCharacters(in: .whitespacesAndNewlines) == "stopped" else { return false }
        // An older session's quit must not hide the latest session's missing quit.
        for line in events.split(separator: "\n").reversed() {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let outcome = event["outcome"] as? String else { continue }
            if outcome == "app_quit" { return false }
            if outcome == "launch" { return true }
        }
        return true
    }
}
