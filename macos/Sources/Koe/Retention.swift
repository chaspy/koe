import Foundation

// 履歴（~/Library/Application Support/Koe/history/YYYY-MM-DD/<id>.*）を残す期間（windows/core/retention.go と同じ規則）。
// 録音（.wav / .alt.wav）は keepDays 日、文字と記録（.json）はその約 2 倍（7→14、14→30、30→60、90→180）残す。0 は消さない。
// さらに history 全体が capBytes を超えたら、古い日の録音から消す。
// 直近 1 日に変わったファイルは消さない（改善ループ・評価が使っている最中のことがある）。
// 日のフォルダとその中のファイルだけを触る（ロック録音の ~/Documents/Koe は対象外）。
enum Retention {
    static let defaultKeepDays = 14
    static let capBytes: Int64 = 1 << 30
    static let protect: TimeInterval = 24 * 3600
    static let every: TimeInterval = 24 * 3600
    static let choices = [7, 14, 30, 90, 0]

    static func textDays(_ keep: Int) -> Int {
        if keep <= 0 { return 0 }
        return keep == 14 ? 30 : keep * 2
    }

    static func label(_ keep: Int) -> String {
        if keep <= 0 { return "ずっと（消さない）" }
        return "\(keep) 日（文字は \(textDays(keep)) 日）" + (keep == defaultKeepDays ? "（既定）" : "")
    }

    struct Result {
        var audio = 0, text = 0, dirs = 0
        var bytes: Int64 = 0
        var sizeAfter: Int64 = 0
    }

    struct File { let url: URL; let day: String; let size: Int64; let mod: Date }

    static func isAudio(_ name: String) -> Bool { name.hasSuffix(".wav") } // .wav と .alt.wav

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    static func isDayDir(_ name: String) -> Bool {
        name.count == 10 && dayFormatter().date(from: name) != nil
    }

    // 日のフォルダの中のファイル（古い日・名前の順）
    static func files(_ dir: URL) -> [File] {
        let fm = FileManager.default
        var out: [File] = []
        for d in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []) where isDayDir(d) {
            let u = dir.appendingPathComponent(d, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: u.path)) ?? [] {
                let f = u.appendingPathComponent(name)
                guard let a = try? fm.attributesOfItem(atPath: f.path), (a[.type] as? FileAttributeType) == .typeRegular else { continue }
                out.append(File(url: f, day: d, size: (a[.size] as? NSNumber)?.int64Value ?? 0, mod: a[.modificationDate] as? Date ?? Date()))
            }
        }
        return out.sorted { $0.day != $1.day ? $0.day < $1.day : $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    static func usage(_ dir: URL) -> (bytes: Int64, files: Int, oldest: String?) {
        let fs = files(dir)
        return (fs.reduce(0) { $0 + $1.size }, fs.count, fs.first?.day)
    }

    // dryRun: 消さずに、消すはずのものを数えるだけ（確認用）
    static func prune(dir: URL, keepDays: Int, capBytes: Int64 = capBytes, now: Date = Date(), dryRun: Bool = false) -> Result {
        var r = Result()
        guard keepDays > 0 else {
            r.sizeAfter = usage(dir).bytes
            return r
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let fmt = dayFormatter()
        let audioCut = fmt.string(from: cal.date(byAdding: .day, value: -keepDays, to: today)!)
        let textCut = fmt.string(from: cal.date(byAdding: .day, value: -textDays(keepDays), to: today)!)
        let protectSince = now.addingTimeInterval(-protect)
        let fm = FileManager.default
        func remove(_ f: File) -> Bool {
            if f.mod > protectSince { return false }
            if !dryRun {
                do { try fm.removeItem(at: f.url) } catch { return false }
            }
            r.bytes += f.size
            if isAudio(f.url.lastPathComponent) { r.audio += 1 } else { r.text += 1 }
            return true
        }
        var left: [File] = []
        var total: Int64 = 0
        for f in files(dir) {
            let cut = isAudio(f.url.lastPathComponent) ? audioCut : textCut
            if f.day < cut && remove(f) { continue }
            left.append(f)
            total += f.size
        }
        // 上限を超えたら、古い日の録音から
        for f in left where total > capBytes {
            if isAudio(f.url.lastPathComponent) && remove(f) { total -= f.size }
        }
        // 空になった日のフォルダ（今日より前）
        if !dryRun {
            let todayName = fmt.string(from: today)
            for d in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []) where isDayDir(d) && d < todayName {
                let u = dir.appendingPathComponent(d)
                if ((try? fm.contentsOfDirectory(atPath: u.path)) ?? ["x"]).isEmpty, (try? fm.removeItem(at: u)) != nil { r.dirs += 1 }
            }
        }
        r.sizeAfter = dryRun ? total : usage(dir).bytes
        return r
    }
}
