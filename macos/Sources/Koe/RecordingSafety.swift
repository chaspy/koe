import Foundation

// Respect the history preference before protecting audio based on capture duration.
enum RecordingSafety {
    static func mustKeep(seconds: Double, held: Double = 0, saveHistory: Bool) -> Bool {
        saveHistory && max(seconds, held) > 2
    }

    static func cancelForMouse(held: Double, seconds: Double) -> Bool {
        held < 1 && seconds < 1
    }

    // A repeated down notification is not proof of a release.
    static func startsNewPress(pressed: Bool, wasDown: Bool) -> Bool {
        pressed && !wasDown
    }

    static func watchAllowed(keyDown: Bool, toggled: Bool) -> Bool {
        toggled && !keyDown
    }

    // Preserve each device generation in order, choosing its audible fallback independently.
    static func choose(_ takes: [[Int16]], hasVoice: ([Int16]) -> Bool) -> [Int16] {
        takes.first(where: hasVoice) ?? takes.first ?? []
    }
}
