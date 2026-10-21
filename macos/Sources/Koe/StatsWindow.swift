import AppKit

// 自分の記録（メニュー →「自分の記録…」）。この Mac の履歴と events を数えるだけで、どこにも送らない。集計は Stats。
// 新しい機能なので既定オフ（defaults write io.github.chaspy.koe statsView -bool true でオン）
final class StatsWindow: NSObject {
    static let shared = StatsWindow()
    static var enabled: Bool { Settings.defaults.bool(forKey: "statsView") }

    private static let menuTag = 0x6B6F_7374
    private static let weeks = 5

    private var window: NSWindow?
    private var range: NSSegmentedControl!
    private var tiles: [(value: NSTextField, note: NSTextField)] = []
    private var heat: HeatView!
    private var heatLabel: NSTextField!
    private var footer: NSTextField!
    private var recs: [Stats.Rec] = []
    private var learned: [Int] = [0, 0, 0]   // 期間ごとの覚えた語の数（今日・7 日・30 日）

    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "自分の記録…", action: #selector(openFromMenu), keyEquivalent: "")
        item.target = shared
        item.tag = menuTag
        item.isHidden = !enabled
        return item
    }

    static func updateMenuItem(in menu: NSMenu) { menu.item(withTag: menuTag)?.isHidden = !enabled }

    @objc private func openFromMenu() { show() }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Events.log("stats_opened")
        footer.stringValue = "数えています…"
        // 履歴を全部読むので裏で数える
        DispatchQueue.global(qos: .userInitiated).async {
            let recs: [Stats.Rec] = StatsWindow.load()
            // events.jsonl を読んで数えるのも裏で（期間を切り替えるたびに読み直さない）
            let ev: String = (try? String(contentsOf: Events.url, encoding: .utf8)) ?? ""
            let now = Date()
            let learned: [Int] = (0..<3).map { Stats.learnedCount(events: ev, from: StatsWindow.from($0, now: now)) }
            DispatchQueue.main.async {
                self.recs = recs
                self.learned = learned
                self.apply()
            }
        }
    }

    // 一度読んだ記録は覚えておき、開き直したときは新しいファイルだけ読む（1 か月ぶんで数秒かかる）。
    // 記録は貼った後にも書き足される（visible_ms など）ので、更新から 1 分たっていないものは覚えず、次に開いたときも読み直す。
    // 読めなかったもの（書いている途中など）も覚えない。読めて数えないと分かったもの（貼っていない・ロック録音）は覚えてよい（後から貼ったことにはならない）
    private static var cache: [String: Stats.Rec?] = [:]
    private static let cacheLock = NSLock()

    private static func load() -> [Stats.Rec] {
        let fm = FileManager.default
        cacheLock.lock(); defer { cacheLock.unlock() }
        var seen = Set<String>()
        var fresh: [Stats.Rec] = []
        let now = Date()
        for d in (try? fm.contentsOfDirectory(atPath: History.dir.path)) ?? [] where Retention.isDayDir(d) {
            let u = History.dir.appendingPathComponent(d)
            for f in (try? fm.contentsOfDirectory(atPath: u.path)) ?? [] where f.hasSuffix(".json") {
                let key = "\(d)/\(f)"
                seen.insert(key)
                if cache[key] != nil { continue }
                let url = u.appendingPathComponent(f)
                guard let r = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
                let rec = Stats.rec(r)
                let mod = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
                if now.timeIntervalSince(mod) >= 60 { cache[key] = .some(rec) } else if let rec { fresh.append(rec) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }   // 消えた履歴は数えない
        return cache.values.compactMap { $0 } + fresh
    }

    @objc private func rangeChanged() { apply() }

    // 期間の始まり（0: 今日 / 1: この 7 日 / 2: この 30 日）
    private static func from(_ seg: Int, now: Date) -> Date {
        let cal = Calendar.current, today = cal.startOfDay(for: now)
        switch seg {
        case 0: return today
        case 1: return cal.date(byAdding: .day, value: -6, to: today)!
        default: return cal.date(byAdding: .day, value: -29, to: today)!
        }
    }

    private func apply() {
        let now = Date()
        let seg = max(0, min(2, range.selectedSegment))
        let s = Stats.summarize(recs, from: Self.from(seg, now: now), now: now, learned: learned[seg])
        let days = Stats.perDay(recs)
        let streak = Stats.streak(days, now: now)
        let speed: (String, String)
        if let v = s.medianVisibleMs {
            speed = (String(format: "%.1f 秒", Double(v) / 1000), "貼ってから画面に出るまで（中央値）")
        } else if let r = s.medianReleaseToPasteMs {
            speed = (String(format: "%.1f 秒", Double(r) / 1000), "キーを離してから文字が入るまで（中央値）")
        } else {
            speed = ("—", "キーを離してから文字が入るまで")
        }
        let values: [(String, String)] = [
            (Stats.number(s.chars) + " 文字", "話して入れた文字（\(Stats.number(s.utterances)) 回）"),
            (s.chars == 0 ? "—" : "約 " + Stats.duration(s.savedSeconds), "打つより早く済んだ時間（下の前提で）"),
            ("\(streak) 日", streak > 0 ? "続けて使っている日数" : "続けて使っている日数（今日使うと 1 日目）"),
            ("\(Stats.number(s.fixes + s.learned)) 回", "Koe が直した数（置き換え \(Stats.number(s.fixes)) 回＋覚えた語 \(Stats.number(s.learned)) 語）"),
            (Stats.duration(s.speakSeconds), "話した時間"),
            speed,
        ]
        for (i, v) in values.enumerated() {
            tiles[i].value.stringValue = v.0
            tiles[i].note.stringValue = v.1
        }
        heat.days = days
        heat.needsDisplay = true
        let keep = Settings.historyKeepDays
        let text = Retention.textDays(keep)
        heatLabel.stringValue = "最近 \(Self.weeks) 週に使った日（濃いほど多く話した日）"
        footer.stringValue = (Settings.saveHistory ? "" : "履歴を残す設定がオフなので、新しく話した分は数えられません。")
            + "「打つより早く済んだ時間」は、キーボードで 1 分に \(Int(Stats.typingPerMinute)) 文字打つとして、打つのにかかる時間から話した時間を引いたものです。"
            + "数えているのはこの Mac に残っている履歴だけで、どこにも送りません"
            + (text > 0 ? "（文字の履歴は \(text) 日ぶん残ります。それより前は数えられません）。" : "。")
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 470), styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Koe 自分の記録"
        w.isReleasedWhenClosed = false
        w.center()
        range = NSSegmentedControl(labels: ["今日", "この 7 日", "この 30 日"], trackingMode: .selectOne, target: self, action: #selector(rangeChanged))
        range.selectedSegment = 1

        let grid = NSGridView(numberOfColumns: 3, rows: 0)
        grid.rowSpacing = 18
        grid.columnSpacing = 18
        var cells: [NSView] = []
        for _ in 0..<6 {
            let v = NSTextField(labelWithString: "…")
            v.font = .systemFont(ofSize: 24, weight: .semibold)
            let n = NSTextField(wrappingLabelWithString: "")
            n.textColor = .secondaryLabelColor
            n.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            n.preferredMaxLayoutWidth = 180
            let stack = NSStackView(views: [v, n])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 2
            stack.widthAnchor.constraint(equalToConstant: 180).isActive = true
            tiles.append((v, n))
            cells.append(stack)
        }
        grid.addRow(with: Array(cells[0..<3]))
        grid.addRow(with: Array(cells[3..<6]))

        heatLabel = NSTextField(labelWithString: "")
        heatLabel.textColor = .secondaryLabelColor
        heat = HeatView(weeks: Self.weeks)
        footer = NSTextField(wrappingLabelWithString: "")
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let c = w.contentView!
        for v in [range, grid, heatLabel, heat, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(v)
        }
        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            range.topAnchor.constraint(equalTo: c.topAnchor, constant: m),
            range.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: m),
            grid.topAnchor.constraint(equalTo: range.bottomAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: m),
            heatLabel.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 24),
            heatLabel.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: m),
            heat.topAnchor.constraint(equalTo: heatLabel.bottomAnchor, constant: 8),
            heat.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: m),
            heat.widthAnchor.constraint(equalToConstant: HeatView.cell * 7 + 30),
            heat.heightAnchor.constraint(equalToConstant: HeatView.cell * CGFloat(Self.weeks)),
            footer.topAnchor.constraint(equalTo: heat.bottomAnchor, constant: 16),
            footer.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: m),
            footer.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(lessThanOrEqualTo: c.bottomAnchor, constant: -m),
        ])
        window = w
    }
}

// 使った日のヒートマップ。1 行 1 週（上が古い週）、左が日曜。濃さは貼った回数（その期間でいちばん多い日を最も濃く）
final class HeatView: NSView {
    static let cell: CGFloat = 22
    var days: [Date: Int] = [:]
    private let weeks: Int

    init(weeks: Int) {
        self.weeks = weeks
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let wd = cal.component(.weekday, from: today) - 1   // 0 = 日曜
        guard let start = cal.date(byAdding: .day, value: -(wd + 7 * (weeks - 1)), to: today) else { return }
        let maxCount = max(1, (0..<(weeks * 7)).compactMap { cal.date(byAdding: .day, value: $0, to: start) }.map { days[$0] ?? 0 }.max() ?? 1)
        let f = DateFormatter()
        f.dateFormat = "M/d"
        for i in 0..<(weeks * 7) {
            guard let d = cal.date(byAdding: .day, value: i, to: start), d <= today else { break }
            let n = days[d] ?? 0
            let r = NSRect(x: CGFloat(i % 7) * Self.cell, y: CGFloat(i / 7) * Self.cell, width: Self.cell - 4, height: Self.cell - 4)
            let color: NSColor = n == 0 ? .quaternaryLabelColor : .systemGreen.withAlphaComponent(0.3 + 0.7 * CGFloat(n) / CGFloat(maxCount))
            color.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
            if d == today {
                NSColor.labelColor.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
                p.lineWidth = 1
                p.stroke()
            }
        }
        // 各週の左端の日付を右に添える
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor]
        for w in 0..<weeks {
            guard let d = cal.date(byAdding: .day, value: w * 7, to: start) else { continue }
            (f.string(from: d) as NSString).draw(at: NSPoint(x: Self.cell * 7 + 2, y: CGFloat(w) * Self.cell + 4), withAttributes: attrs)
        }
    }
}
