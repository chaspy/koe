import AppKit

// 入らなかった録音を、履歴からもう一度文字起こしする（メニュー →「最近の文字起こし」の下の段）。
// 結果は貼らずにクリップボードと「最近の文字起こし」に入れる（押したときの貼り先がもう分からないため）。
// 履歴の json には「やり直した時刻と文字数」だけ足し、events にも数と種類だけ書く（本文は書かない）
final class Retranscriber {
    // gone: 押した録音がもう無い（履歴の期間を過ぎた・もうやり直した）。busy: ほかの録音をやり直している最中
    enum Outcome { case ok(String), unheard, failed, gone, busy }

    private let server: WhisperServer
    private var running: String?
    // 一覧はメニューを開く前に裏で作っておく（メインスレッドで履歴の json を何百件も読まない）。
    // json は 1 件 1 回だけ読み（更新から 1 分以内のもの・読めなかったものは次も読み直す）、一覧に要る欄だけ覚えておく（list はメインスレッド、seen は queue の上だけで触る）
    private var list: [RetryList.Item] = []
    private var seen: [String: [String: Any]] = [:]
    private let queue = DispatchQueue(label: "koe.retranscriber", qos: .utility)

    init(server: WhisperServer) { self.server = server }

    // Recovery of existing history is always available; new saves respect saveHistory.
    static var enabled: Bool { true }

    // 取り消した録音を履歴に残す（残す期間は履歴の決まりどおり）。まだ文字起こししていないので文は無い
    static func saveCancelled(_ u: Utterance, _ cap: Capture, reason: String, held: Double) {
        u.capture = cap
        u.record["outcome"] = "cancelled"
        u.record["dropped"] = true
        u.record["cancel_reason"] = reason
        u.record["hold_seconds"] = round(held * 100) / 100
        u.record["audio_seconds"] = cap.seconds
        u.record["voiced_seconds"] = round(cap.voicedSeconds * 100) / 100
        u.record["peak"] = cap.peak
        u.record["device"] = cap.device
        if !cap.quality.isEmpty { u.record["quality"] = cap.quality }
        u.record["pasted"] = NSNull()
        if History.save(id: History.newID(), wav: cap.url, record: u.record, alt: cap.alt?.url) {
            try? FileManager.default.removeItem(at: cap.url)
            if let alt = cap.alt?.url { try? FileManager.default.removeItem(at: alt) }
        }
    }

    // 一覧を裏で作り直す。メニュー（本体）を開いたときと、やり直しが終わったときに呼ぶ
    func refresh() {
        guard Self.enabled else { return }
        queue.async {
            let fm = FileManager.default
            let now = Date()
            var keep: [String: [String: Any]] = [:]
            var fresh: [[String: Any]] = []
            for d in RetryList.dayDirs(now: now) {
                let u = History.dir.appendingPathComponent(d)
                for f in (try? fm.contentsOfDirectory(atPath: u.path)) ?? [] where f.hasSuffix(".json") {
                    let key = "\(d)/\(f)"
                    if let r = self.seen[key] { keep[key] = r; continue }
                    let url = u.appendingPathComponent(f)
                    guard let r = (try? Data(contentsOf: url)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { continue }
                    let slim = RetryList.slim(r)
                    // 書いている途中・書き足される前かもしれないので、更新から 1 分たっていないものは覚えず次も読み直す。読めなかったものも覚えない
                    let mod = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? now
                    if now.timeIntervalSince(mod) >= 60 && slim["outcome"] as? String != "pending" { keep[key] = slim } else { fresh.append(slim) }
                }
            }
            self.seen = keep   // 期間を過ぎた日は忘れる
            let items = RetryList.items(Array(keep.values) + fresh, now: now) { day, audio in
                fm.fileExists(atPath: History.dir.appendingPathComponent(day).appendingPathComponent(audio).path)
            }
            DispatchQueue.main.async { self.list = items }
        }
    }

    // 「最近の文字起こし」の下に、入らなかった録音を足す。一覧はメニュー（本体）を開いたときに裏で作ったものを出す
    func addMenuItems(to menu: NSMenu, target: AnyObject, action: Selector) {
        guard Self.enabled else { return }
        guard !list.isEmpty || running != nil else { return }
        menu.addItem(.separator())
        let head = NSMenuItem(title: "入らなかった録音（押すと、もう一度文字起こししてクリップボードに入れます）", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let now = Date()
        for i in list {
            let item = NSMenuItem(title: RetryList.title(i, now: now) + (running == i.id ? "  — 文字起こし中…" : ""),
                                  action: running == nil ? action : nil, keyEquivalent: "")
            item.target = target
            item.representedObject = i.id
            item.isEnabled = running == nil
            menu.addItem(item)
        }
    }

    // id の録音をもう一度文字起こしする。done はメインスレッドで呼ぶ
    func run(id: String, ready: Bool, done: @escaping (Outcome) -> Void) {
        guard running == nil else { return done(.busy) }
        let item = list.first(where: { $0.id == id })
        let wav = item.map { History.dir.appendingPathComponent($0.day).appendingPathComponent("\($0.id).wav") }
        guard Self.enabled, let item, let wav, FileManager.default.fileExists(atPath: wav.path) else {
            Events.log("retranscribe_failed", ["reason": "gone"])
            refresh()
            return done(.gone)
        }
        guard ready else {
            Events.log("retranscribe_failed", ["outcome": item.outcome, "reason": "not_ready"])
            return done(.failed)
        }
        running = id
        let started = Date()
        func finish(_ o: Outcome, prompt: Bool) {
            running = nil
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            switch o {
            case .ok(let text):
                mark(item, chars: text.count)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
                Events.log("retranscribed", ["outcome": item.outcome, "chars": text.count, "ms": ms, "seconds": item.seconds, "prompt": prompt])
            case .unheard:
                Events.log("retranscribe_failed", ["outcome": item.outcome, "reason": "unheard", "ms": ms])
            case .failed, .gone, .busy:
                Events.log("retranscribe_failed", ["outcome": item.outcome, "reason": "error", "ms": ms])
            }
            refresh()
            done(o)
        }
        // 窓は 30 秒全体・温度のフォールバックあり（繰り返しのやり直しと同じ、いちばん粘る設定）。
        // 決まり文句しか出なければ、プロンプトなしでもう 1 回
        func attempt(_ prompt: String) {
            server.transcribe(wav: wav, prompt: prompt, keepLines: Settings.keepLines, seconds: item.seconds,
                              audioCtx: 0, temperatureInc: "0.2") { result in
                DispatchQueue.main.async {
                    guard case .success(let raw) = result else { return finish(.failed, prompt: !prompt.isEmpty) }
                    var t = Glossary.autocorrect(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                    if isRepetitive(t) { t = collapseRepeats(t) }
                    if hasStockPhrase(t) { t = removeStockPhrases(t) }
                    if RetryList.usable(t, hallucinations: hallucinations) { return finish(.ok(t), prompt: !prompt.isEmpty) }
                    if !prompt.isEmpty { return attempt("") }
                    finish(.unheard, prompt: false)
                }
            }
        }
        attempt(Settings.whisperPrompt(previous: nil))
    }

    // やり直して入ったことを履歴に書く（一覧に二度出さない）。文は書かない
    private func mark(_ item: RetryList.Item, chars: Int) {
        let url = History.dir.appendingPathComponent(item.day).appendingPathComponent("\(item.id).json")
        guard let data = try? Data(contentsOf: url), var r = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        r["retranscribed_at"] = ISO8601DateFormatter().string(from: Date())
        r["retranscribed_chars"] = chars
        if let out = try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys]) { try? out.write(to: url) }
        list.removeAll { $0.id == item.id }
        let key = "\(item.day)/\(item.id).json"
        queue.async { self.seen[key]?["retranscribed_at"] = r["retranscribed_at"] }
    }
}
