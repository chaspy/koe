import AppKit

// 自己診断（#211）のメニュー「診断する…」と、強い所見の知らせ（1 日 1 回まで・録音中は出さない）、
// 「これで直った？」の再確認。判定は DiagnosisLog / SelfDiagnosis。保存するのは数・日付・種類の名前だけ
final class DiagnosisNotice: MenuBarNotice {
    static let shared = DiagnosisNotice()
    private static let shownDayKey = "diagnosisNoticeDay"
    private static let recheckKindsKey = "diagnosisRecheckKinds"
    private static let recheckCountKey = "diagnosisRecheckCount"   // 再確認を始めてから録った数

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/diagnosis.jsonl")
    }

    // 使い方の「録音の不調のよくある原因」（公開 repo の docs/usage-ja.md）
    static let causesURL = URL(string: "https://github.com/chaspy/koe/blob/main/docs/usage-ja.md#"
        + "録音の不調のよくある原因".addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)!)!

    private var history: [DiagRecording] = []
    private var loaded = false

    private func current() -> [DiagRecording] {
        if !loaded { history = DiagnosisLog.load(Self.url); loaded = true }
        return history
    }

    /// 録音が 1 件終わるたびに呼ぶ（main.swift の finish）
    func note(_ r: DiagRecording) {
        history = DiagnosisLog.append(r, to: Self.url)
        loaded = true
        if !recheckKinds.isEmpty {
            Settings.defaults.set(Settings.defaults.integer(forKey: Self.recheckCountKey) + 1, forKey: Self.recheckCountKey)
        }
    }

    private var recheckKinds: [DiagKind] {
        (Settings.defaults.stringArray(forKey: Self.recheckKindsKey) ?? []).compactMap(DiagKind.init(rawValue:))
    }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    override func check() {
        guard !isShowing, !busy() else { return }
        let h = current()
        let kinds = recheckKinds
        if let result = DiagnosisLog.recheck(kinds, newRecordings: Settings.defaults.integer(forKey: Self.recheckCountKey), history: h) {
            Settings.defaults.removeObject(forKey: Self.recheckKindsKey)
            Settings.defaults.removeObject(forKey: Self.recheckCountKey)
            Events.log("diagnosis_recheck", ["kinds": kinds.count, "cleared": result.values.filter { $0 }.count])
            let t = DiagnosisLog.recheckText(result)
            present(title: t.title, detail: t.detail, detailLines: 3, width: 360,
                    buttons: [button("閉じる", #selector(dismiss)), button("診断する…", #selector(openReport))], hideAfter: 12)
            return
        }
        guard kinds.isEmpty else { return }   // 確かめている間は同じ知らせを重ねない
        let today = Self.day(Date())
        guard let f = DiagnosisLog.dailyNotice(SelfDiagnosis.findings(h), today: today,
                                               lastShownDay: Settings.defaults.string(forKey: Self.shownDayKey), busy: busy()) else { return }
        Settings.defaults.set(today, forKey: Self.shownDayKey)
        Events.log("diagnosis_notice", ["kind": f.kind.rawValue, "affected": f.affected])
        present(title: f.message, detail: f.fix, detailLines: 3, width: 360,
                buttons: [button("閉じる", #selector(dismiss)), button("診断する…", #selector(openReport))], hideAfter: 12)
    }

    @objc private func openReport() {
        dismiss()
        showReport()
    }

    /// メニューの「診断する…」
    func showReport() {
        let h = current()
        let findings = SelfDiagnosis.findings(h)
        Events.log("diagnosis_opened", ["findings": findings.count, "recordings": h.count])
        let a = NSAlert()
        a.messageText = "Koe の自己診断"
        a.informativeText = DiagnosisLog.report(findings, count: min(h.count, SelfDiagnosis.pasteWindow))
        if findings.isEmpty {
            a.addButton(withTitle: "閉じる")
        } else {
            a.informativeText += "\n\n直し方を試したら「直したので確かめる」を押して、何度か話してください。直ったかをお知らせします"
            a.addButton(withTitle: "直したので確かめる")
            a.addButton(withTitle: "閉じる")
        }
        a.addButton(withTitle: "Claude Code で詳しく調べる")
        a.addButton(withTitle: "よくある原因を見る")
        NSApp.activate(ignoringOtherApps: true)
        let answer = a.runModal()
        if answer == NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + (findings.isEmpty ? 2 : 3)) {
            NSWorkspace.shared.open(Self.causesURL)
            return
        }
        if answer == NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + (findings.isEmpty ? 1 : 2)) {
            writeAgentBundle(h)
            return
        }
        guard answer == .alertFirstButtonReturn, !findings.isEmpty else { return }
        Settings.defaults.set(findings.map { $0.kind.rawValue }, forKey: Self.recheckKindsKey)
        Settings.defaults.set(0, forKey: Self.recheckCountKey)
        Events.log("diagnosis_recheck_started", ["kinds": findings.count])
    }

    // デスクトップに Koe-diagnose-<日時>/ を書き、Claude Code への頼み方をクリップボードに入れる
    private func writeAgentBundle(_ h: [DiagRecording]) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe-diagnose-\(f.string(from: Date()))", isDirectory: true)
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        let settings = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "io.github.chaspy.koe") ?? [:]
        let object = AgentBundle.json(version: version, os: ProcessInfo.processInfo.operatingSystemVersionString,
                                      settings: settings, recordings: h,
                                      history: Settings.saveHistory ? History.recentRecords(100) : [],
                                      devices: AudioDevices.inputs().map(\.name))
        do {
            try AgentBundle.write(object, to: dir)
        } catch {
            Events.log("agent_bundle_failed")
            let e = NSAlert()
            e.messageText = "書き出せませんでした"
            e.informativeText = "デスクトップに書き込めるか確かめてください"
            e.runModal()
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(AgentBundle.prompt(dir: dir), forType: .string)
        Events.log("agent_bundle_written", ["recordings": h.count])
        NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(AgentBundle.readmeName)])
        let done = NSAlert()
        done.messageText = "Claude Code に渡す情報を書き出しました"
        done.informativeText = "デスクトップの \(dir.lastPathComponent) に数値だけを書きました（話した内容・音声・ウィンドウ名・機器の名前は入れていません）。\n\n頼み方をクリップボードに入れたので、Claude Code に貼り付けてください"
        done.runModal()
    }
}
