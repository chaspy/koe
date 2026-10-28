import Foundation

// Copy audio first. A failed write must never consume the only source file.
enum RecordingArchive {
    static func wavData(_ pcm: [Int16], sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataSize = UInt32(pcm.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        return d
    }

    static func save(root: URL, id: String, wav: URL, record: [String: Any], alt: URL? = nil) throws {
        let fm = FileManager.default
        let day = root.appendingPathComponent(String(id.prefix(10)), isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        let dest = day.appendingPathComponent("\(id).wav")
        try fm.copyItem(at: wav, to: dest)
        var rec = record
        rec["id"] = id
        rec["audio"] = "\(id).wav"
        rec["reference"] = NSNull()
        if alt != nil { rec["alt_audio"] = "\(id).alt.wav" }
        let data = try JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: day.appendingPathComponent("\(id).json"), options: .atomic)
        // The primary recovery record is durable even if the optional alternate fails.
        if let alt {
            try? fm.copyItem(at: alt, to: day.appendingPathComponent("\(id).alt.wav"))
        }
    }
}
