import Darwin
import Foundation

// Koe only talks to the whisper-server it started itself: a free loopback port is chosen for each
// launch, and the server counts as up only while that child is running and holds the listening socket.
enum OwnServer {
    struct Listener: Equatable {
        let address: String  // IPv4 dotted quad, "" for anything else
        let port: Int
    }

    // A free port on 127.0.0.1, chosen by the kernel.
    static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        return port > 0 ? port : nil
    }

    // Whether one of the listeners is 127.0.0.1:port.
    static func holds(_ listeners: [Listener], port: Int) -> Bool {
        listeners.contains { $0.port == port && $0.address == "127.0.0.1" }
    }

    // Up = the child is running, it holds the port, and /health answered 200.
    static func isUp(running: Bool, holdsPort: Bool, healthStatus: Int?) -> Bool {
        running && holdsPort && healthStatus == 200
    }

    // The TCP sockets the process is listening on (libproc; works for our own child processes).
    static func listeners(pid: pid_t) -> [Listener] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var result: [Listener] = []
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, infoSize) == infoSize,
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            var address = ""
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
                var a = ini.insi_laddr.ina_46.i46a_addr4
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil { address = String(cString: buf) }
            }
            result.append(Listener(address: address, port: port))
        }
        return result
    }
}

enum TranscriptText {
    // Drops control characters before the text is pasted. Newlines are kept (the caller has already
    // joined lines as configured); tabs become spaces; bidirectional overrides are removed too.
    static func removingControls(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            if s == "\n" { out.append(s); continue }
            if s == "\t" { out.append(" "); continue }
            if s.properties.generalCategory == .control { continue }
            if (0x202A...0x202E).contains(s.value) || (0x2066...0x2069).contains(s.value) { continue }
            out.append(s)
        }
        return String(out)
    }
}
