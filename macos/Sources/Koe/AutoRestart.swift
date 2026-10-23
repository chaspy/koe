import Foundation

// Opt-in only. The job watches Koe; launchd never owns the interactive app process.
enum AutoRestart {
    static let label = "io.github.chaspy.koe.restart"
    enum Action: Equatable { case stop, wait, restart }
    static func action(enabled: Bool, alive: Bool, quitRequested: Bool, hasSession: Bool) -> Action {
        guard enabled, hasSession else { return .stop }
        if alive { return .wait }
        return quitRequested ? .stop : .restart
    }
    struct Session: Codable {
        let identity: ServerLifecycle.Identity
        var quitRequested: Bool
    }
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/restart-session.json")
    }
    static func read(_ url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }
    static func write(_ session: Session, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
    }
    static func plist(executable: String, bundle: String, destination: URL, session: URL) -> [String: Any] {
        ["Label": label,
         "ProgramArguments": [executable, "--auto-restart-agent", bundle, destination.path, session.path],
         "KeepAlive": ["SuccessfulExit": false],
         "RunAtLoad": true,
         "ThrottleInterval": 30,
         "LimitLoadToSessionType": "Aqua",
         "ProcessType": "Background"]
    }
    typealias Run = ([String]) throws -> Void
    // Injected runner and paths keep tests away from launchctl and ~/Library/LaunchAgents.
    static func enable(executable: String, bundle: String, destination: URL, session: URL,
                       domain: String, run: Run) throws {
        let data = try PropertyListSerialization.data(fromPropertyList:
            plist(executable: executable, bundle: bundle, destination: destination, session: session),
            format: .xml, options: 0)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        do { try run(["bootstrap", domain, destination.path]) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
    }
    static func disable(destination: URL, domain: String, jobLabel: String = label, run: Run) throws {
        // Removing first also tells an in-flight watcher not to start another app.
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try run(["bootout", "\(domain)/\(jobLabel)"])
    }
    // A normal quit must either persist intent or disarm the watcher. Throwing means
    // the caller must cancel termination and let the user retry; never mark it recorded.
    static func protectQuit(session: Session?, pid: Int32, save: (Session) throws -> Void,
                            disarm: () throws -> Void) throws -> Bool {
        guard var session, session.identity.pid == pid else {
            try disarm()
            return false
        }
        session.quitRequested = true
        do { try save(session); return true }
        catch { try disarm(); return false }
    }
    static func launchctl(_ arguments: [String]) throws {
        try execute("/bin/launchctl", arguments)
    }
    private static func execute(_ executable: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "KoeAutoRestart", code: Int(p.terminationStatus))
        }
    }
    // Only this watcher is owned by launchd. `open` starts Koe outside its process group.
    static func watch(bundle: String, destination: URL, sessionURL: URL) -> Int32 {
        var observedLiveSession = false
        var openedAt: Date?
        while true {
            let session = read(sessionURL)
            let decision = action(enabled: FileManager.default.fileExists(atPath: destination.path),
                                  alive: session?.identity.isCurrent ?? false,
                                  quitRequested: session?.quitRequested ?? false, hasSession: session != nil)
            switch decision {
            case .stop: return 0
            case .wait:
                observedLiveSession = true
                openedAt = nil
            case .restart:
                // Failure triggers KeepAlive.SuccessfulExit=false; throttle is launchd's job.
                if observedLiveSession { return 1 }
                if let openedAt {
                    if Date().timeIntervalSince(openedAt) > 30 { return 1 }
                } else {
                    do { try execute("/usr/bin/open", ["-g", bundle]); openedAt = Date() }
                    catch { return 1 }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}
