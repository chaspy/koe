import Darwin
import Foundation

// PID alone is not ownership: the executable and kernel start time must match too.
enum ServerLifecycle {
    struct Identity: Codable, Equatable {
        let pid: Int32
        let path: String
        let seconds: UInt64
        let microseconds: UInt64

        static func read(_ pid: Int32) -> Identity? {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return Identity(pid: pid, path: String(cString: path), seconds: info.pbi_start_tvsec,
                            microseconds: info.pbi_start_tvusec)
        }
        var isCurrent: Bool { Self.read(pid) == self }
    }
    struct Record: Codable {
        let parent: Identity
        let server: Identity
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/servers", isDirectory: true)
    }
    static func save(_ record: Record, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: .atomic)
    }
    static func read(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }
    // Only recorded processes are considered. No process-name scan, port scan, or broad kill.
    @discardableResult static func stop(_ record: Record) -> Bool {
        guard record.server.isCurrent else { return false }
        guard kill(record.server.pid, SIGTERM) == 0 else { return false }
        for _ in 0..<20 {
            if !record.server.isCurrent { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if record.server.isCurrent { _ = kill(record.server.pid, SIGKILL) }
        return true
    }
    static func cleanOrphans(in directory: URL) -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var count = 0
        for url in files where url.pathExtension == "json" {
            guard let record = read(url), !record.parent.isCurrent else { continue }
            if stop(record) { count += 1 }
            try? FileManager.default.removeItem(at: url)
        }
        return count
    }
    // A separate Koe helper holds only the read end. Kernel EOF also covers SIGKILL/crashes.
    static func watch(_ url: URL) {
        _ = FileHandle.standardInput.readDataToEndOfFile()
        if let record = read(url) { stop(record) }
        try? FileManager.default.removeItem(at: url)
    }
}

struct RunningMarker {
    let url: URL
    // Replacing the previous run's marker consumes its notice once for this launch.
    func begin() throws -> Bool {
        let previous = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("running\n".utf8).write(to: url, options: .atomic)
        return previous
    }
    func finish() { try? FileManager.default.removeItem(at: url) }
}
