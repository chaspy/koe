import AppKit

// 辞書を見る画面（メニュー →「辞書を見る…」）。出どころ別（自分の辞書・組織の辞書・用語パック）に一覧し、
// 自分の辞書は「自動で覚えた（✦）」「自分で入れた（✎）」の印で分ける。判定は GlossaryCatalog。
// 語は画面に出すだけ（記録には開いたことと数だけ残す）
final class GlossaryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = GlossaryWindow()

    enum Tab: Int { case personal, org, packs }

    private struct Row {
        let term: String
        let sure: [String]
        let noteOnly: [String]
        let origin: GlossaryCatalog.Origin?
        let learnedAt: Date?
        let used: Int
        let inHint: Bool
        let cleanupReason: TermRules.Rejection?
    }

    private var window: NSWindow?
    private var tabs: NSSegmentedControl!
    private var search: NSSearchField!
    private var recentOnly: NSButton!
    private var cleanupOnly: NSButton!
    private var about: NSTextField!
    private var openFile: NSButton!
    private var table: NSTableView!
    private var empty: NSTextField!
    private var footer: NSTextField!
    private var rows: [[Row]] = [[], [], []]
    private var shown: [Row] = []
    private var tab: Tab = .personal
    private var orgLabel = ""
    private var packTitles: [String] = []
    private var hintCount = 0, notInHint = 0

    // recent: 「この 1 週間に覚えた語」を絞り込んで開く（お知らせから開いたとき）
    func show(tab: Tab = .personal, recent: Bool = false) {
        if window == nil { build() }
        reload()
        self.tab = tab
        tabs.selectedSegment = tab.rawValue
        recentOnly.state = recent ? .on : .off
        cleanupOnly.state = .off
        // Offer the list once, without deleting or rewriting any dictionary entry.
        if tab == .personal, !recent, !Settings.defaults.bool(forKey: "termCleanupOffered"),
           rows[0].contains(where: { $0.cleanupReason != nil }) {
            cleanupOnly.state = .on
            Settings.defaults.set(true, forKey: "termCleanupOffered")
        }
        search.stringValue = ""
        apply()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Events.log("glossary_opened", ["tab": ["personal", "org", "packs"][tab.rawValue], "recent": recent])
    }

    // 新しい機能なので既定オフ（defaults write io.github.chaspy.koe glossaryView -bool true でオン）。
    // オフの間はメニューに出さず、週 1 回のお知らせも出さない
    static var enabled: Bool { Settings.defaults.bool(forKey: "glossaryView") }

    // メニューの「辞書を見る…」。この 1 週間に覚えた語があれば「（今週 +N 語）」を添える（メニューを開いたときに数える）
    private static let menuTag = 0x6B6F_6762
    static func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "辞書を見る…", action: #selector(openFromMenu), keyEquivalent: "")
        item.target = shared
        item.tag = menuTag
        item.isHidden = !enabled
        return item
    }

    static func updateMenuItem(in menu: NSMenu) {
        guard let item = menu.item(withTag: menuTag) else { return }
        item.isHidden = !enabled
        guard enabled else { return }
        let n = LearnedNotice.recentCount()
        item.title = "辞書を見る…" + (n > 0 ? "（今週 +\(n) 語）" : "")
    }

    @objc private func openFromMenu() { show() }

    // MARK: data

    private func reload() {
        let koe = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe")
        let learned = GlossaryCatalog.learnedDates(events: (try? String(contentsOf: Events.url, encoding: .utf8)) ?? "")
        let candidates = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: koe.appendingPathComponent("glossary_candidates.json")))) as? [String: [String: Any]] ?? [:])
        let cands = Set(candidates.keys)
        let personal = Glossary.personal, packs = Glossary.packs, org = Glossary.org
        let aliasKeys = Set((personal + packs + org).flatMap(\.aliases).map(TermRules.aliasKey))
        let counts = Glossary.usageCounts(personal + packs + org)
        let hint = Glossary.whisperTerms(limit: 120)
        let inHint = Set(hint)
        func row(_ e: Glossary.Entry, mark: Bool) -> Row {
            let l = GlossaryCatalog.aliasLabels(e.aliases)
            return Row(term: e.term, sure: l.sure, noteOnly: l.noteOnly,
                       origin: mark ? GlossaryCatalog.origin(e.term, learned: learned, candidates: cands) : nil,
                       learnedAt: learned[e.term], used: counts[e.term] ?? 0, inHint: inHint.contains(e.term),
                       cleanupReason: mark ? TermRules.rejection(e.term, aliases: aliasKeys,
                           person: candidates[e.term]?["person"] as? Bool == true) : nil)
        }
        rows = [personal.map { row($0, mark: true) }, org.map { row($0, mark: false) }, packs.map { row($0, mark: false) }]
        hintCount = hint.count
        notInHint = GlossaryCatalog.notInHint(all: (personal + packs + org).map(\.term), included: hint)
        // 組織の辞書の取得時刻: URL なら取り込んだ控え、ファイルならそのファイルの更新日時
        if let src = Settings.orgGlossary, !src.isEmpty {
            let isURL = src.hasPrefix("http://") || src.hasPrefix("https://")
            let path = isURL ? Glossary.orgCacheURL.path : (src as NSString).expandingTildeInPath
            let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            orgLabel = GlossaryCatalog.orgFetchedLabel(m, now: Date(), url: isURL)
        } else {
            orgLabel = ""
        }
        let on = Set(Settings.enabledPacks)
        packTitles = Glossary.availablePacks.filter { on.contains($0.id) }.map(\.title)
        for (i, n) in [personal.count, org.count, packs.count].enumerated() {
            tabs.setLabel(["自分の辞書", "組織の辞書", "用語パック"][i] + "（\(n)）", forSegment: i)
        }
    }

    private func apply() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        var list = rows[tab.rawValue]
        if tab == .personal, recentOnly.state == .on {
            list = list.filter { ($0.learnedAt ?? .distantPast) >= weekAgo }.sorted { ($0.learnedAt ?? .distantPast) > ($1.learnedAt ?? .distantPast) }
        }
        if tab == .personal, cleanupOnly.state == .on { list = list.filter { $0.cleanupReason != nil } }
        if !q.isEmpty {
            list = list.filter { r in ([r.term] + r.sure + r.noteOnly).contains { $0.lowercased().contains(q) } }
        }
        if let d = table.sortDescriptors.first, let key = d.key {
            list.sort { a, b in
                let less: Bool
                switch key {
                case "used": less = a.used != b.used ? a.used < b.used : a.term < b.term
                default: less = a.term.localizedStandardCompare(b.term) == .orderedAscending
                }
                return d.ascending ? less : !less
            }
        }
        shown = list
        table.tableColumn(withIdentifier: .init("mark"))?.isHidden = tab != .personal
        recentOnly.isHidden = tab != .personal
        cleanupOnly.isHidden = tab != .personal
        openFile.isHidden = tab != .personal
        about.stringValue = tab == .personal && cleanupOnly.state == .on
            ? "見直し候補の一覧です（自動では削除しません）。語にカーソルを合わせると理由を表示します。不要な語は「辞書のファイルを開いて直す…」から手動で削除できます。"
            : aboutText()
        empty.stringValue = emptyText(filtered: !q.isEmpty || (tab == .personal && (recentOnly.state == .on || cleanupOnly.state == .on)))
        empty.isHidden = !shown.isEmpty
        table.reloadData()
        footer.stringValue = "文字起こしのヒントに入るのは約 120 文字ぶんで、いま \(hintCount) 語が入っています（右の列の ●）。"
            + (notInHint > 0 ? "\(notInHint) 語は入りきっていません。用語の条件を満たす語を優先し、その中で最近よく使う順に入ります。" : "")
            + "ヒントに入らない語でも、自分の辞書と用語パックにある「聞き間違えた形」は貼る前に直します。"
    }

    private func aboutText() -> String {
        switch tab {
        case .personal:
            return "✦ は Koe が使いながら覚えた語、✎ は自分で入れた語です。「聞き間違えた形」が文字起こしに出てきたら、左の書き方に直して貼ります。"
        case .org:
            guard !orgLabel.isEmpty else { return "組織の辞書は設定されていません。配られた設定ファイルをメニューの「設定ファイルを読み込む…」で読み込むと入ります。" }
            return "組織で配っている辞書です。文字起こしのヒントと、受け取る AI へのメモに使います（ここでは直せません）。\(orgLabel)"
        case .packs:
            guard !packTitles.isEmpty else { return "オンにしている用語パックはありません。メニューの「用語パック」でオンにできます。" }
            return "オンにしている用語パック: \(packTitles.joined(separator: "、"))。切り替えはメニューの「用語パック」から。"
        }
    }

    private func emptyText(filtered: Bool) -> String {
        if filtered { return tab == .personal && recentOnly.state == .on && search.stringValue.isEmpty ? "この 1 週間に覚えた語はまだありません" : "見つかりませんでした" }
        switch tab {
        case .personal: return "まだ語がありません。使っていると Koe が覚えます（「使うほど賢くする」をオンにしたとき）"
        case .org: return orgLabel.isEmpty ? "" : "組織の辞書に語がありません"
        case .packs: return packTitles.isEmpty ? "" : "語がありません"
        }
    }

    // MARK: actions

    @objc private func tabChanged() {
        tab = Tab(rawValue: tabs.selectedSegment) ?? .personal
        apply()
    }

    @objc private func toggleRecent() { apply() }

    func controlTextDidChange(_ obj: Notification) { apply() }

    // 自分の辞書のファイルを開く（1 行 1 語。語のあとにタブで聞き間違えた形を ／ 区切り）。無ければ作る
    @objc private func openPersonal() {
        let path = (Settings.glossaryPath as NSString).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? "# Koe 個人の辞書（1 行 1 語。語のあとにタブを入れて、聞き間違えた形を ／ で区切って書く）\n".write(toFile: path, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // ファイルを直して戻ってきたら読み直す
    func windowDidBecomeKey(_ notification: Notification) {
        guard window != nil else { return }
        reload()
        apply()
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }
        let r = shown[row]
        let cell = tableView.makeView(withIdentifier: .init("cell-\(id)"), owner: self) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = .init("cell-\(id)")
            let t = NSTextField(labelWithString: "")
            t.translatesAutoresizingMaskIntoConstraints = false
            t.lineBreakMode = .byTruncatingTail
            c.addSubview(t)
            c.textField = t
            NSLayoutConstraint.activate([t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                                         t.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                                         t.centerYAnchor.constraint(equalTo: c.centerYAnchor)])
            return c
        }()
        let t = cell.textField!
        t.textColor = .labelColor
        t.alignment = .left
        t.toolTip = nil
        switch id {
        case "mark":
            t.stringValue = r.origin == .learned ? "✦ 自動" : "✎ 自分"
            t.textColor = r.origin == .learned ? .systemBlue : .secondaryLabelColor
            t.toolTip = r.origin == .learned ? "使っているうちに Koe が覚えた語" : "自分で入れた語（または覚えた記録が残っていない語）"
        case "term":
            t.stringValue = r.term
            t.toolTip = r.cleanupReason?.label
        case "sure":
            t.stringValue = r.sure.isEmpty ? "—" : r.sure.joined(separator: "、")
            t.textColor = r.sure.isEmpty ? .tertiaryLabelColor : .labelColor
            t.toolTip = r.sure.isEmpty ? nil : r.sure.joined(separator: "\n")
        case "note":
            t.stringValue = r.noteOnly.isEmpty ? "—" : r.noteOnly.joined(separator: "、")
            t.textColor = r.noteOnly.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor
            t.toolTip = r.noteOnly.isEmpty ? nil : "普通の言葉と同じ形なので直さず、受け取る AI へのメモにだけ使います:\n" + r.noteOnly.joined(separator: "\n")
        case "used":
            t.stringValue = r.used > 0 ? "\(r.used) 回" : "—"
            t.alignment = .right
            t.textColor = r.used > 0 ? .labelColor : .tertiaryLabelColor
        case "hint":
            t.stringValue = r.inHint ? "●" : ""
            t.alignment = .center
            t.textColor = .systemGreen
            t.toolTip = r.inHint ? "いま文字起こしのヒントに入っている" : nil
        default: break
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) { apply() }

    // MARK: layout

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Koe の辞書"
        w.minSize = NSSize(width: 560, height: 380)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        tabs = NSSegmentedControl(labels: ["自分の辞書", "組織の辞書", "用語パック"], trackingMode: .selectOne, target: self, action: #selector(tabChanged))
        search = NSSearchField()
        search.placeholderString = "語・聞き間違えた形で探す"
        search.delegate = self
        recentOnly = NSButton(checkboxWithTitle: "この 1 週間に覚えた語だけ", target: self, action: #selector(toggleRecent))
        cleanupOnly = NSButton(checkboxWithTitle: "見直し候補だけ（削除は手動）", target: self, action: #selector(toggleRecent))
        openFile = NSButton(title: "辞書のファイルを開いて直す…", target: self, action: #selector(openPersonal))
        openFile.bezelStyle = .rounded
        about = NSTextField(wrappingLabelWithString: "")
        about.textColor = .secondaryLabelColor
        footer = NSTextField(wrappingLabelWithString: "")
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        table = NSTableView()
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.allowsColumnReordering = false
        for (id, title, width, sortable) in [("mark", "", 64.0, false), ("term", "語", 150.0, true), ("sure", "聞き間違えた形（直す）", 220.0, false),
                                             ("note", "AI へのメモだけ", 130.0, false), ("used", "最近 300 回", 76.0, true),
                                             ("hint", "ヒント", 44.0, false)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = width
            c.minWidth = 36
            if sortable { c.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: id == "term") }
            if id == "used" { c.headerToolTip = "最近の 300 回の発話に、この語（か聞き間違えた形）が出てきた数" }
            if id == "hint" { c.headerToolTip = "いま文字起こしのヒント（whisper）に入っている語" }
            table.addTableColumn(c)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        empty = NSTextField(labelWithString: "")
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        let content = w.contentView!
        for v in [tabs, search, recentOnly, cleanupOnly, openFile, about, scroll, empty, footer] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        let m: CGFloat = 16
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: m),
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            search.centerYAnchor.constraint(equalTo: tabs.centerYAnchor),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            search.widthAnchor.constraint(equalToConstant: 220),
            about.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            about.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            about.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            recentOnly.topAnchor.constraint(equalTo: about.bottomAnchor, constant: 8),
            recentOnly.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            openFile.centerYAnchor.constraint(equalTo: recentOnly.centerYAnchor),
            openFile.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            cleanupOnly.topAnchor.constraint(equalTo: recentOnly.bottomAnchor, constant: 6),
            cleanupOnly.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            scroll.topAnchor.constraint(equalTo: cleanupOnly.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: m),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -m),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -m),
        ])
        window = w
    }
}
