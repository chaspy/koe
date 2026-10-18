import AppKit
import AVFoundation
import ApplicationServices
import Carbon
import CoreAudio
import AudioToolbox
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Settings
//
// すべて `defaults write io.github.chaspy.koe <key> <value>` で上書きできる。

enum Settings {
    static let defaults = UserDefaults.standard
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static var whisperHome: String {
        defaults.string(forKey: "whisperHome") ?? "\(home)/.local/src/whisper.cpp"
    }
    // アプリに同梱した whisper-server を優先する。無ければ自分でビルドした whisper.cpp
    static var serverBinary: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/whisper-server").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "\(whisperHome)/build/bin/whisper-server"
    }
    // モデルは初回起動時に Application Support へ自動でダウンロードする
    static let modelFileName = "ggml-large-v3-turbo.bin"
    static var modelURL: URL {
        URL(string: defaults.string(forKey: "modelURL") ?? "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(modelFileName)")!
    }
    static var downloadedModel: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/models/\(modelFileName)").path
    }
    static var model: String {
        if let m = defaults.string(forKey: "model") { return m }
        let fm = FileManager.default
        for c in [downloadedModel, "\(whisperHome)/models/\(modelFileName)", "\(whisperHome)/models/ggml-large-v3.bin"] where fm.fileExists(atPath: c) {
            return c
        }
        return downloadedModel
    }
    static var language: String { defaults.string(forKey: "language") ?? "ja" }
    // whisper の窓の大きさ: "auto"（既定。Mac では毎回 30 秒ぶん全体。#165）/ 0（毎回 30 秒ぶん全体）/ フレーム数（AudioWindow.swift）
    static var audioCtx: Int { AudioWindow.setting(defaults.object(forKey: "audioCtx")) }
    static var port: Int {
        let p = defaults.integer(forKey: "port")
        return p > 0 ? p : 18080
    }
    // 句読点と疑問符を付けさせるための初期プロンプト
    static var prompt: String {
        defaults.string(forKey: "prompt") ?? "これで合ってる？はい、承知しました。それって本当？では、次の作業に進みましょう。"
    }
    // 押している間だけ録音するキー。既定は右 Command (54)
    static var hotkeyKeyCode: UInt16 {
        let k = defaults.integer(forKey: "hotkeyKeyCode")
        return k > 0 ? UInt16(k) : 54
    }
    static var autoEnter: Bool {
        get { defaults.object(forKey: "autoEnter") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoEnter") }
    }
    // Enter を自動で送るアプリ（ターミナル系）。それ以外（Teams・Slack 等）には貼るだけで送信しない
    static var enterApps: [String] {
        defaults.stringArray(forKey: "enterApps") ?? [
            "com.googlecode.iterm2", "com.apple.Terminal", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
            "net.kovidgoyal.kitty", "org.alacritty", "io.alacritty", "com.github.wez.wezterm",
        ]
    }
    static var shouldEnter: Bool { shouldEnter(bundle: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) }
    static func shouldEnter(bundle: String?) -> Bool {
        guard autoEnter, let id = bundle else { return false }
        return enterApps.contains(id)
    }
    // 文字起こしの間に別のアプリが前に出たら、押したときのアプリ・ウィンドウに戻してから貼る（BUG-FOCUS、既定オン）
    static var restoreFocus: Bool {
        get { defaults.object(forKey: "restoreFocus") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "restoreFocus") }
    }
    // 押し方: hold＝押している間だけ録音（既定） / toggle＝短く押すと開始、もう一度短く押すと終了して貼る
    static var toggleMode: Bool {
        get { defaults.string(forKey: "pressMode") == "toggle" }
        set { defaults.set(newValue ? "toggle" : "hold", forKey: "pressMode") }
    }
    // ターミナル以外（Google Docs 等）に貼るとき、whisper の区切りごとに改行する。既定はオフ
    static var lineBreaks: Bool {
        get { defaults.bool(forKey: "lineBreaks") }
        set { defaults.set(newValue, forKey: "lineBreaks") }
    }
    static var keepLines: Bool {
        guard lineBreaks, let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
        return !enterApps.contains(id)
    }
    // マイクの注意（Bluetooth・蓋を閉じた内蔵マイク、MicNotice.swift）。新しい機能なので既定オフ
    static var micNotice: Bool { defaults.object(forKey: "micNotice") as? Bool ?? false }
    // これより短い押下は誤操作とみなして捨てる
    static var minHoldSeconds: Double {
        let v = defaults.double(forKey: "minHoldSeconds")
        return v > 0 ? v : 0.2
    }
    // 録音の開始・終了で効果音を鳴らす
    static var sounds: Bool {
        get { defaults.object(forKey: "sounds") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sounds") }
    }
    // アプリ同梱の音（start / stop）か、macOS 標準の音の名前（Ping 等）
    static var startSound: String { defaults.string(forKey: "startSound") ?? "start" }
    static var stopSound: String { defaults.string(forKey: "stopSound") ?? "stop" }
    static var failSound: String { defaults.string(forKey: "failSound") ?? "fail" }
    // 文字起こし後に LLM で整形する（OpenAI 互換エンドポイント）
    static var llmEnabled: Bool {
        get { defaults.object(forKey: "llmEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "llmEnabled") }
    }
    static var llmEndpoint: String { defaults.string(forKey: "llmEndpoint") ?? "http://localhost:11434/v1" }
    static var llmModel: String { defaults.string(forKey: "llmModel") ?? "qwen2.5:7b" }
    static var llmAPIKey: String? { defaults.string(forKey: "llmAPIKey") }
    // 個人の辞書（1 行 1 語、# はコメント）。whisper の初期プロンプトと LLM 整形の両方に使う。
    // 改善ループが履歴から自動で育てる
    static var glossaryPath: String {
        defaults.string(forKey: "glossaryPath")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Koe/glossary.txt").path
    }
    static var glossaryTerms: [String] { Glossary.personal.map(\.term) }
    // 組織の辞書（配布される読み取り専用の辞書）。ファイルパスか http(s) の URL
    static var orgGlossary: String? { defaults.string(forKey: "orgGlossary") }
    // 有効にする用語パック（packs/*.txt のファイル名）。既定は開発者向け
    // 共有の用語パックの取り込み元（gh:owner/repo/path か https の URL）
    static var packSources: [String] { defaults.stringArray(forKey: "packSources") ?? [] }
    // 社員名簿（<ID><TAB><本名>）の取り込み元（gh:owner/repo/path か https の URL）。設定したときだけ改善ループに渡す（People.swift）
    static var peopleSources: [String] { defaults.stringArray(forKey: "peopleSources") ?? [] }
    static var enabledPacks: [String] {
        get { defaults.stringArray(forKey: "enabledPacks") ?? ["developer"] }
        set { defaults.set(newValue, forKey: "enabledPacks") }
    }
    // 直前の発話（同じアプリ・3 分以内）を初期プロンプトの頭に足す。
    // 会話の流れが分かると同音異義語・専門用語の取り違えが減る（koe_bench.py で CER 6.5% → 3.9%）
    static var contextPrompt: Bool {
        get { defaults.object(forKey: "contextPrompt") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "contextPrompt") }
    }
    static func whisperPrompt(previous: String?) -> String {
        guard contextPrompt, let prev = previous, !prev.isEmpty else { return whisperPrompt }
        return String(prev.suffix(150)) + " " + whisperPrompt
    }

    // whisper の初期プロンプトは 224 トークンまでなので、用語は約 120 文字ぶんだけ入れる
    static var whisperPrompt: String {
        let terms = Glossary.whisperTerms(limit: 120)
        return terms.isEmpty ? prompt : "\(terms.joined(separator: "、"))。\(prompt)"
    }
    static var llmTimeout: Double {
        let v = defaults.double(forKey: "llmTimeout")
        return v > 0 ? v : 8
    }
    // 録音と文字起こし結果を保存して、後でモデル・プロンプトの比較評価に使う
    static var saveHistory: Bool {
        get { defaults.object(forKey: "saveHistory") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "saveHistory") }
    }
    // 履歴の録音を残す日数（文字と記録はその約 2 倍。0 は消さない）。Retention を参照
    static var historyKeepDays: Int {
        get { defaults.object(forKey: "historyKeepDays") as? Int ?? Retention.defaultKeepDays }
        set { defaults.set(newValue, forKey: "historyKeepDays") }
    }
    // 比較用に、使わなかった側のマイクの録音も保存する（マイクの A/B 比較）
    static var saveAllMics: Bool {
        get { defaults.object(forKey: "saveAllMics") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "saveAllMics") }
    }
    // 既定のマイクがミュート（完全な無音）の間は別のマイクで録る
    static var fallbackMic: Bool {
        get { defaults.object(forKey: "fallbackMic") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "fallbackMic") }
    }
    static var fallbackMicName: String? { defaults.string(forKey: "fallbackMicName") }
    // Koe が使うマイク。nil は自動（システムの既定。ミュート中は別のマイク）
    static var micName: String? {
        get { defaults.string(forKey: "micName") }
        set { defaults.set(newValue, forKey: "micName") }
    }
    // 貼り付け後にクリップボードを元に戻すか。既定はオフ＝文字起こしが残るので、貼り付けに失敗しても ⌘V で貼り直せる
    // iTerm に貼ったあと、文が画面に出るまでの時間を測る（画面の中身を AppleScript で読む。オンにして初めて測るときにオートメーションの許可を求める）。
    // 既定はオフ: オンだと iTerm を使う人全員に「Koe が iTerm を制御しようとしています」のダイアログが出るため。オフの間は許可を聞かない
    static var measureVisible: Bool { defaults.object(forKey: "measureVisible") as? Bool ?? false }
    static var restoreClipboard: Bool {
        get { defaults.object(forKey: "restoreClipboard") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "restoreClipboard") }
    }
    // 改善ループ（使うほど辞書が育ち、伝達の判定が付く）。発話を improveEndpoint に送るので既定はオフ
    static var improveEnabled: Bool {
        get { defaults.object(forKey: "improveEnabled") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "improveEnabled") }
    }
    // 改善ループの LLM。既定は Claude Code（claude -p）を呼ぶコマンド型で、追加の従量課金がかからない。
    // improveProvider = "command"（標準入力でプロンプトを渡し、標準出力で答えを受け取る CLI）か "api"（OpenAI 互換）
    static var improveProvider: String { defaults.string(forKey: "improveProvider") ?? "command" }
    static var improveCommand: String { defaults.string(forKey: "improveCommand") ?? "claude -p --model sonnet" }
    // 送り先の表示用（同意ダイアログ・メニュー）
    static var improveTarget: String {
        improveProvider == "api" ? "\(improveEndpoint)（\(improveModel)）" : "コマンド: \(improveCommand)"
    }
    static var improveEndpoint: String { defaults.string(forKey: "improveEndpoint") ?? "" }
    static var improveModel: String { defaults.string(forKey: "improveModel") ?? "" }
    static var improveBatch: Int {
        let v = defaults.integer(forKey: "improveBatch")
        return v > 0 ? v : 30
    }
    // 認証: improveAPIKey か、トークンを標準出力に出すコマンド improveTokenCommand（OAuth の短命トークン向け）
    static func improveAuth() -> String? {
        if let k = defaults.string(forKey: "improveAPIKey"), !k.isEmpty { return k }
        guard let cmd = defaults.string(forKey: "improveTokenCommand"), !cmd.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        let token = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return token?.isEmpty == false ? token : nil
    }
    // マイクを開きっぱなしにして押す直前の音も拾う（頭切れ防止）
    static var warmMic: Bool {
        get { defaults.object(forKey: "warmMic") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "warmMic") }
    }
}

// 修飾キーの keyCode → 左右を区別できるデバイス依存フラグ
let deviceModifierMask: [UInt16: UInt] = [
    54: 0x10,    // right command
    55: 0x08,    // left command
    61: 0x40,    // right option
    58: 0x20,    // left option
    60: 0x04,    // right shift
    56: 0x02,    // left shift
    62: 0x2000,  // right control
    59: 0x01,    // left control
    63: 0x800000, // fn（地球儀キー）
]

// 無音・雑音で whisper がよく出す幻聴
let hallucinations = [
    "ご視聴ありがとうございました", "ご視聴ありがとうございました。",
    "ありがとうございました", "ありがとうございました。",
    "おやすみなさい", "おやすみなさい。",
    "(音楽)", "(拍手)", "[音楽]", "[BLANK_AUDIO]",
]

// MARK: - whisper-server

final class WhisperServer {
    private var process: Process?
    var baseURL: URL { URL(string: "http://127.0.0.1:\(Settings.port)")! }

    func start(onReady: @escaping (Result<Void, Error>) -> Void) {
        isAlive { alive in
            if alive { return onReady(.success(())) }
            // 起動中（読み込み待ち）なら、もう 1 本は起動せずに待つ
            if self.process?.isRunning == true {
                return self.waitUntilReady(deadline: Date().addingTimeInterval(120), onReady: onReady)
            }
            do {
                try self.launch()
                self.waitUntilReady(deadline: Date().addingTimeInterval(120), onReady: onReady)
            } catch {
                onReady(.failure(error))
            }
        }
    }

    private func launch() throws {
        guard FileManager.default.isExecutableFile(atPath: Settings.serverBinary) else {
            throw NSError(domain: "Koe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "whisper-server が見つかりません: \(Settings.serverBinary)"])
        }
        guard FileManager.default.fileExists(atPath: Settings.model) else {
            throw NSError(domain: "Koe", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "モデルが見つかりません: \(Settings.model)"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Settings.serverBinary)
        p.arguments = [
            "-m", Settings.model,
            "-l", Settings.language,
            "--host", "127.0.0.1",
            "--port", String(Settings.port),
            "-t", "4",
            "--prompt", Settings.prompt,
        ] + VAD.serverArguments()
        VAD.serverHasModel = p.arguments!.contains("-vm")
        let log = Self.logURL
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        p.standardOutput = handle
        p.standardError = handle
        try p.run()
        process = p
    }

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("koe", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("whisper-server.log")
    }

    func isAlive(_ done: @escaping (Bool) -> Void) {
        var req = URLRequest(url: baseURL)
        req.timeoutInterval = 1
        URLSession.shared.dataTask(with: req) { _, resp, _ in
            done((resp as? HTTPURLResponse) != nil)
        }.resume()
    }

    private func waitUntilReady(deadline: Date, onReady: @escaping (Result<Void, Error>) -> Void) {
        isAlive { alive in
            if alive { return onReady(.success(())) }
            if let p = self.process, !p.isRunning {
                return onReady(.failure(NSError(domain: "Koe", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "whisper-server が起動直後に終了しました (\(Self.logURL.path))"])))
            }
            if Date() > deadline {
                return onReady(.failure(NSError(domain: "Koe", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "whisper-server の起動がタイムアウトしました"])))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                self.waitUntilReady(deadline: deadline, onReady: onReady)
            }
        }
    }

    // audioCtx / temperatureInc: nil = サーバーの既定（全体の枠・温度のフォールバックあり）
    func transcribe(wav: URL, prompt: String, keepLines: Bool = false, seconds: Double = 0,
                    audioCtx: Int? = nil, temperatureInc: String? = nil,
                    done: @escaping (Result<String, Error>) -> Void) {
        let boundary = "whisperja-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "text")
        field("prompt", prompt)
        field("temperature", "0.0")
        if let audioCtx { field("audio_ctx", String(audioCtx)) }
        if let temperatureInc { field("temperature_inc", temperatureInc) }
        for (name, value) in VAD.requestFields() { field(name, value) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        guard let audio = try? Data(contentsOf: wav) else {
            return done(.failure(NSError(domain: "Koe", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "録音ファイルを読めませんでした"])))
        }
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        // 長い録音（ロック録音）は文字起こしに時間がかかる
        req.timeoutInterval = max(120, seconds)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error { return done(.failure(error)) }
            // 崩れた出力は多バイト文字の途中で切れることがある。空にせず U+FFFD に置き換えて、
            // 呼び出し側で「崩れた」と分かるようにする（AudioWindow.looksGarbled）
            let raw = String(decoding: data ?? Data(), as: UTF8.self)
            let text = raw
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: keepLines ? "\n" : " ")
            done(.success(text))
        }.resume()
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

// MARK: - Glossary
//
// 2 層: 組織の辞書（orgGlossary。配布・読み取り専用）と個人の辞書（glossaryPath。改善ループが育てる）。
// 形式はどちらも 1 行 1 語、タブの後に別名（／区切り）を書ける。# はコメント。
// whisper の初期プロンプトは約 120 文字しか入らないので、個人の辞書を優先し、
// 組織の辞書からは最近の発話に出てきた語を優先して詰める。

enum Glossary {
    struct Entry { let term: String; let aliases: [String] }

    static func parse(_ text: String) -> [Entry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { return nil }
            let parts = l.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let aliases = parts.count > 1
                ? parts[1].split(whereSeparator: { $0 == "／" || $0 == "/" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            return Entry(term: parts[0], aliases: aliases)
        }
    }

    private static func read(_ path: String) -> String {
        (try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
    }

    static var personal: [Entry] { parse(read(Settings.glossaryPath)) }

    // 用語パック: 分野ごとの汎用の語（packs/*.txt をアプリに同梱。~/Library/Application Support/Koe/packs/ に置けば自作も使える）
    // 別名の先頭に ~ を付けたものは紛らわしい誤変換（例: ~マジ → マージ）。置き換えず、受け取る側の AI へのメモにだけ使う
    struct Pack { let id: String; let title: String; let url: URL }
    static var availablePacks: [Pack] {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("packs")) }
        dirs.append(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe/packs"))
        var seen = Set<String>(), out: [Pack] = []
        for d in dirs {
            for f in ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where f.pathExtension == "txt" {
                let id = f.deletingPathExtension().lastPathComponent
                guard !seen.contains(id) else { continue }
                seen.insert(id)
                let first = read(f.path).split(separator: "\n").first.map(String.init) ?? id
                let title = first.hasPrefix("#") ? first.replacingOccurrences(of: "# Koe 用語パック:", with: "").trimmingCharacters(in: .whitespaces) : id
                out.append(Pack(id: id, title: title, url: f))
            }
        }
        return out
    }
    static var packs: [Entry] {
        let on = Set(Settings.enabledPacks)
        return availablePacks.filter { on.contains($0.id) }.flatMap { parse(read($0.url.path)) }
    }
    static func sure(_ aliases: [String]) -> [String] { aliases.filter { !$0.hasPrefix("~") } }

    // 共有の用語パックを取り込む（1 日 1 回）。packSources の各要素:
    //   gh:owner/repo/path/to/pack.txt  … gh CLI で private リポジトリから取る（gh にログイン済みが前提）
    //   https://…/pack.txt              … そのまま取る
    // 取り込んだファイルは Application Support/Koe/packs/<ファイル名> に置き、enabledPacks にあれば使われる
    static func refreshPackSources(force: Bool = false) {
        let sources = Settings.packSources
        guard !sources.isEmpty else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe/packs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async {
            for src in sources {
                let name = (src as NSString).lastPathComponent
                let dest = dir.appendingPathComponent(name)
                if !force, let m = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(m) < 86400 { continue }
                let data = fetch(src)
                // 中身がパックの形式（テキスト）であることだけ確かめて差し替える
                if let d = data, let text = String(data: d, encoding: .utf8), !text.isEmpty, !text.hasPrefix("{") {
                    try? d.write(to: dest)
                    Events.log("pack_synced", ["source": src, "terms": parse(text).count])
                } else {
                    Events.log("pack_sync_failed", ["source": src])
                }
            }
            DispatchQueue.main.async { exportForReceivers() }
        }
    }

    // 取り込み元（gh:owner/repo/path は gh CLI で、https はそのまま）から中身を取る。失敗は nil
    static func fetch(_ src: String) -> Data? {
        if src.hasPrefix("gh:") {
            let parts = src.dropFirst(3).split(separator: "/", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "gh api repos/\(parts[0])/\(parts[1])/contents/\(parts[2]) -H 'Accept: application/vnd.github.raw'"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        }
        guard let url = URL(string: src) else { return nil }
        return try? Data(contentsOf: url)
    }

    static func ambiguous(_ aliases: [String]) -> [String] { aliases.filter { $0.hasPrefix("~") }.map { String($0.dropFirst()) } }

    static var orgCacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/org_glossary.cache.txt")
    }

    static var org: [Entry] {
        guard let src = Settings.orgGlossary, !src.isEmpty else { return [] }
        if src.hasPrefix("http://") || src.hasPrefix("https://") { return parse(read(orgCacheURL.path)) }
        return parse(read(src))
    }

    // URL の組織の辞書を 1 日 1 回取り直す
    static func refreshOrgIfNeeded() {
        guard let src = Settings.orgGlossary, let url = URL(string: src), url.scheme?.hasPrefix("http") == true else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: orgCacheURL.path)
        if let m = attrs?[.modificationDate] as? Date, Date().timeIntervalSince(m) < 86400 { return }
        URLSession.shared.dataTask(with: url) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            try? FileManager.default.createDirectory(at: orgCacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: orgCacheURL)
        }.resume()
    }

    // 最近の発話（直近 300 件）に出てきた件数。数えるのは重い（辞書 約 500 語 × 300 件の突き合わせで数秒かかっていた）ので、
    // 裏で数えておき、文字起こしのときは数え終わった結果を使うだけにする（10 分空いた後の最初の 1 回が 3 秒遅れていた）
    private static var usage: [String: Int] = [:]
    private static var usageAt = Date.distantPast
    private static var usageRefreshing = false
    private static let usageLock = NSLock()
    static func usageCounts(_ entries: [Entry]) -> [String: Int] {
        usageLock.lock(); let cached = usage, stale = Date().timeIntervalSince(usageAt) >= 600; usageLock.unlock()
        if stale { refreshUsage(entries) }
        return cached
    }
    static func refreshUsage(_ entries: [Entry]? = nil, ifOlderThan age: TimeInterval = 0) {
        usageLock.lock()
        if usageRefreshing || Date().timeIntervalSince(usageAt) < age { usageLock.unlock(); return }
        usageRefreshing = true
        usageLock.unlock()
        let list = entries ?? (personal + packs + org)
        DispatchQueue.global(qos: .utility).async {
            let started = Date()
            // NSString の検索は Swift の String.contains よりずっと速い
            let texts = History.recentPasted(300).map { $0.text.lowercased() as NSString }
            var u: [String: Int] = [:]
            for e in list {
                let keys = ([e.term] + e.aliases.map { $0.hasPrefix("~") ? String($0.dropFirst()) : $0 }).map { $0.lowercased() }.filter { $0.count >= 2 }
                let n = texts.reduce(0) { acc, t in acc + (keys.contains { t.range(of: $0).location != NSNotFound } ? 1 : 0) }
                if n > 0 { u[e.term] = n }
            }
            usageLock.lock(); usage = u; usageAt = Date(); usageRefreshing = false; usageLock.unlock()
            Events.log("usage_refreshed", ["ms": Int(Date().timeIntervalSince(started) * 1000), "terms": list.count])
        }
    }

    // 個人・組織の辞書をまとめて、最近の発話に出てきた回数が多い順に詰める。
    // 出てこなかった個人の語はその後ろ（ファイルの並び順）。別名（誤変換された形）でも数える
    static func whisperTerms(limit: Int) -> [String] {
        let p = personal
        let k = packs.filter { e in !p.contains { $0.term == e.term } }
        let o = org.filter { e in !p.contains { $0.term == e.term } && !k.contains { $0.term == e.term } }
        let counts = usageCounts(p + k + o)
        let used = (p + k + o).map(\.term).filter { counts[$0] != nil }.sorted { counts[$0]! > counts[$1]! }
        // 最近出てこなかった語は、個人の辞書（本人が育てた・入れた語）を先に、パックを後に
        let rest = (p + k).map(\.term).filter { counts[$0] == nil }
        var out: [String] = []
        var length = 0
        for t in used + rest {
            if length + t.count > limit { continue }
            out.append(t)
            length += t.count + 1
        }
        return out
    }

    // 個人の辞書の別名は、実際に起きた誤変換の形（改善ループが記録する）。出てきたら正しい表記に置き換える。
    // 一度覚えた誤変換は二度と出ず、直前の発話を文脈に渡すときに誤変換を引き継がない
    static func autocorrect(_ text: String) -> String { autocorrectWithLog(text).text }

    // 置き換えた内容も返す（効き目の計測用。履歴に autocorrected として残す）
    static func autocorrectWithLog(_ text: String) -> (text: String, applied: [String]) {
        var applied: [String] = []
        // 「マジ>(され|し|する)」のように > の後に続く語の条件を書いた別名は、その語が続くときだけ置き換える（AliasReplace）
        let pairs = (personal + packs).flatMap { e in sure(e.aliases).filter { $0.count >= 2 && $0 != e.term }.map { ($0, e.term) } }
            .sorted { $0.0.count > $1.0.count }
        var t = text
        for (wrong, right) in pairs {
            let r = AliasReplace.apply(t, wrong: wrong, right: right)
            if r.hit { applied.append("\(wrong.split(separator: ">").first ?? "")→\(right)") }
            t = r.text
        }
        return (t, applied)
    }

    // 受け取る側の AI（Claude Code 等）に渡す「誤変換されやすい語」の一覧。
    // 音声入力の文を受け取った AI がこれを読めば、化けた語を自分で読み替えられる（追加の費用も待ち時間もない）。
    // 既定は Claude Code の設定フォルダ（CLAUDE.md から「@~/.claude/koe-voice-glossary.md」で読み込める）
    static var receiverURL: URL {
        if let p = Settings.defaults.string(forKey: "receiverGlossaryPath") { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/koe-voice-glossary.md")
    }
    // 全部入りの版（常時は読み込まない。意味が取れない語があったときに受け取る側が grep する）
    static var receiverFullURL: URL {
        receiverURL.deletingPathExtension().appendingPathExtension("full.md")
    }
    // 社員の名前と呼び方の一覧（peopleSources を設定したときだけ）。分からない名前に出会ったときだけ引く
    static var receiverPeopleURL: URL {
        receiverURL.deletingLastPathComponent().appendingPathComponent("koe-people.md")
    }
    // 常時読み込む版は短くする（毎回の会話の文脈を食うため）。最近の発話に出た語を優先して上位だけ載せ、残りは全部入りの版へ
    static let receiverShortRows = 20
    static func exportForReceivers() {
        // 個人の辞書とパックで同じ語は 1 つにまとめる（別名は合わせる）
        var merged: [(term: String, aliases: [String])] = []
        for e in personal + packs {
            if let i = merged.firstIndex(where: { $0.term == e.term }) {
                merged[i].aliases = merged[i].aliases + e.aliases.filter { !merged[i].aliases.contains($0) }
            } else { merged.append((e.term, e.aliases)) }
        }
        func row(_ e: (term: String, aliases: [String])) -> String {
            let s = sure(e.aliases).map { $0.replacingOccurrences(of: ">", with: "（直後が ") + ($0.contains(">") ? " のとき）" : "") }, amb = ambiguous(e.aliases)
            var line = "- \(e.term)"
            if !s.isEmpty { line += " ← \(s.joined(separator: "、"))" }
            if !amb.isEmpty { line += "（文脈によっては「\(amb.joined(separator: "」「"))」と化ける）" }
            return line
        }
        let withAliases = merged.filter { !$0.aliases.isEmpty }
        // 最近の発話に出た語（正しい表記か化けた形）を先に。同じなら個人の辞書の順
        let counts = usageCounts((personal + packs).filter { !$0.aliases.isEmpty })
        let ranked = withAliases.enumerated().sorted { x, y in
            let cx = counts[x.element.term] ?? 0, cy = counts[y.element.term] ?? 0
            return cx != cy ? cx > cy : x.offset < y.offset
        }.map(\.element)
        let terms = merged.filter { $0.aliases.isEmpty }.map(\.term)
        let orgRows = org.filter { e in !e.aliases.isEmpty && !merged.contains { $0.term == e.term } }.map { row(($0.term, $0.aliases)) }
        let fullPath = receiverFullURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")

        var head = "# 音声入力（Koe）の誤変換メモ\n\n"
        head += "ユーザーは音声入力（Koe・whisper）でも入力する。文字起こしの誤変換が混ざるので、意味が通らない語は音の近い語として読み替えてから解釈すること。読み替えたことは一言添える。\n\n"
        head += "音声入力では疑問の「？」が落ちて「。」になることがある。口語の文末（〜てる、〜ない、〜だっけ、〜ってこと）が質問か断定か曖昧なときは、質問として受け取り、答えてから進めること。\n\n"

        var short = head
        short += "意味が取れない語があって下の一覧に無いときは、全部入りの一覧 `\(fullPath)` を grep してから読み替える（\(withAliases.count + orgRows.count) 語）。\n\n"
        let people = PeopleStore.all
        if !people.isEmpty {
            let peoplePath = receiverPeopleURL.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            short += "人の名前・呼び名が誰のことか分からないときは `\(peoplePath)` を grep する（社員の ID・本名と、分かった呼び方）。\n\n"
            let k = PeopleStore.known()
            try? People.receiverNote(people, called: k.called, wrongs: k.wrongs).write(to: receiverPeopleURL, atomically: true, encoding: .utf8)
        }
        if !ranked.isEmpty { short += "## よく起きる誤変換（正しい表記 ← 化けた形）\n\n" + ranked.prefix(receiverShortRows).map(row).joined(separator: "\n") + "\n" }
        try? short.write(to: receiverURL, atomically: true, encoding: .utf8)

        var full = head
        if !ranked.isEmpty { full += "## 実際に起きた誤変換（正しい表記 ← 化けた形）\n\n" + ranked.map(row).joined(separator: "\n") + "\n\n" }
        if !orgRows.isEmpty { full += "## 組織の辞書（社内の語と別の書き方）\n\n" + orgRows.joined(separator: "\n") + "\n\n" }
        if !terms.isEmpty { full += "## よく使う語（この表記が正しい）\n\n" + terms.joined(separator: "、") + "\n" }
        try? full.write(to: receiverFullURL, atomically: true, encoding: .utf8)
    }

    // LLM には全語を渡す（組織の辞書は別名つき）
    static var llmBlock: String {
        let p = personal + packs
        let names = Set(p.map(\.term))
        return (p + org.filter { !names.contains($0.term) }).prefix(500).map { e in
            let al = e.aliases.map { $0.hasPrefix("~") ? String($0.dropFirst()) : $0 }
            return al.isEmpty ? e.term : "\(e.term) ← \(al.joined(separator: "／"))"
        }.joined(separator: "\n")
    }
}

// MARK: - People

// 社員名簿（peopleSources）の取り込み・キャッシュと、改善ループで分かった呼び方の記録。判定は People.swift。
// 名簿の中身はログ・診断情報に出さない（件数だけ）。whisper の初期プロンプト・LLM 整形には使わない
enum PeopleStore {
    private static var koeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe")
    }
    private static var cacheDir: URL { koeDir.appendingPathComponent("people") }
    // 改善ループで分かった呼び方・化けた形（{"called": {ID: [...]}, "wrongs": {ID: [...]}}）
    private static var knownURL: URL { koeDir.appendingPathComponent("people_known.json") }

    // 取り込んだ名簿（peopleSources が空なら空）
    static var all: [People.Person] {
        guard !Settings.peopleSources.isEmpty else { return [] }
        var seen = Set<String>()
        return Settings.peopleSources.flatMap { src in
            People.parse((try? String(contentsOf: cacheDir.appendingPathComponent((src as NSString).lastPathComponent), encoding: .utf8)) ?? "")
        }.filter { seen.insert($0.id.lowercased()).inserted }
    }

    // 1 日 1 回取り直す（パックと同じ口）。記録には件数だけ残し、取り込み元も中身も書かない
    static func refresh(force: Bool = false) {
        let sources = Settings.peopleSources
        guard !sources.isEmpty else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async {
            for src in sources {
                let dest = cacheDir.appendingPathComponent((src as NSString).lastPathComponent)
                if !force, let m = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.modificationDate] as? Date,
                   Date().timeIntervalSince(m) < 86400 { continue }
                if let d = Glossary.fetch(src), let text = String(data: d, encoding: .utf8), !text.hasPrefix("{"), !People.parse(text).isEmpty {
                    try? d.write(to: dest)
                    Events.log("people_synced", ["people": People.parse(text).count])
                } else {
                    Events.log("people_sync_failed")
                }
            }
            DispatchQueue.main.async { Glossary.exportForReceivers() }
        }
    }

    static func known() -> (called: [String: [String]], wrongs: [String: [String]]) {
        let j = (try? JSONSerialization.jsonObject(with: Data(contentsOf: knownURL))) as? [String: [String: [String]]] ?? [:]
        return (j["called"] ?? [:], j["wrongs"] ?? [:])
    }

    static func remember(called: [(who: String, called: String)], wrongs: [(who: String, wrong: String)]) {
        guard !called.isEmpty || !wrongs.isEmpty else { return }
        var (c, w) = known()
        for x in called where !(c[x.who] ?? []).contains(x.called) { c[x.who, default: []].append(x.called) }
        for x in wrongs where !(w[x.who] ?? []).contains(x.wrong) { w[x.who, default: []].append(x.wrong) }
        if let data = try? JSONSerialization.data(withJSONObject: ["called": c, "wrongs": w], options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: knownURL)
        }
    }
}

// MARK: - Audio devices

enum AudioDevices {
    struct Device { let id: AudioDeviceID; let name: String; let transport: UInt32 }

    private static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == 0 ? v : nil
    }

    static func defaultInput() -> AudioDeviceID? {
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioDeviceID(0))
    }

    static func inputs() -> [Device] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == 0 else { return [] }
        return ids.compactMap { id in
            var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var ss = UInt32(0)
            guard AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss) == 0, ss > 0 else { return nil }
            var name: CFString = "" as CFString
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var ns = UInt32(MemoryLayout<CFString>.size)
            _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &na, 0, nil, &ns, $0) }
            let transport = get(id, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0
            return Device(id: id, name: name as String, transport: transport)
        }
    }

    // メニューに出す実マイク（仮想・集約デバイスは除く）
    static func selectable() -> [Device] {
        inputs().filter { $0.transport != kAudioDeviceTransportTypeVirtual && $0.transport != kAudioDeviceTransportTypeAggregate }
    }

    // ミュート時の代わりのマイク。設定 fallbackMicName が優先。なければ USB マイク > 内蔵マイク
    // dead は開いても無音だったマイク（蓋を閉じた MacBook の内蔵マイク等）
    static func fallback(excluding primary: AudioDeviceID?, dead: Set<AudioDeviceID>? = nil) -> Device? {
        let all = inputs()
        let dead = dead ?? (Settings.micNotice ? MicNotice.dead(all.map { ($0.id, $0.transport) }, lidClosed: MicNotice.lidClosed()) : [])
        let candidates = all.filter {
            $0.id != primary && !dead.contains($0.id)
                && $0.transport != kAudioDeviceTransportTypeVirtual && $0.transport != kAudioDeviceTransportTypeAggregate
        }
        if let want = Settings.fallbackMicName, let d = candidates.first(where: { $0.name.contains(want) }) { return d }
        return candidates.first { $0.transport == kAudioDeviceTransportTypeUSB }
            ?? candidates.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
            ?? candidates.first
    }
}

// MARK: - Model download

// モデルが無ければダウンロードする（進捗を返す）。途中で失敗したら .part を残さず消す
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    private var progress: ((Double) -> Void)?
    private var done: ((Result<Void, Error>) -> Void)?
    private let dest: URL

    init(dest: String) { self.dest = URL(fileURLWithPath: dest) }

    func start(progress: @escaping (Double) -> Void, done: @escaping (Result<Void, Error>) -> Void) {
        self.progress = progress
        self.done = done
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        session.downloadTask(with: Settings.modelURL).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            done?(.failure(NSError(domain: "Koe", code: 30, userInfo: [NSLocalizedDescriptionKey: "モデルのダウンロードに失敗しました (HTTP \(code))"])))
            return
        }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            done?(.success(()))
        } catch {
            done?(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { done?(.failure(error)) }
    }
}

// MARK: - Recorder
//
// AVAudioEngine の入力を 16kHz mono Int16 に変換して溜める。
// - 離した後も tailSeconds だけ録り続けて語尾の切れを防ぐ
// - warm モードではマイクを開きっぱなしにし、押す直前 preRollSeconds 分も含めて頭切れを防ぐ
// - デバイス変更・スリープ復帰でエンジンが止まる／無音しか来なくなるので、検知して張り直す
// - 前後の無音は削ってから書き出す（無音が長いと whisper が「ご視聴ありがとうございました」を作る）
// - Teams 認定のヘッドセット等は、会議でミュートすると本体側でマイクを切り、OS には完全な無音を流す。
//   既定のマイクが無音になったら別のマイク（fallback）も開き、無音の間はそちらで録る

struct Capture {
    let url: URL
    let seconds: Double        // 録れた長さ
    let voicedSeconds: Double  // 無音を削った後の長さ。0 なら声が入っていない
    let peak: Int              // 最大振幅。0 ならマイクから無音しか来ていない
    let device: String         // 録ったマイク
    var quality: [String: Any] = [:]   // 音質の指標（AudioQuality.measure）
    var alt: (device: String, url: URL, quality: [String: Any])? = nil  // 使わなかった側のマイクの録音（比較用）
}

// 音質の客観指標（発話ごとに記録し、伝達の失敗との関係やマイクの比較に使う）
//   level_db: 声の部分の平均 RMS（dBFS）/ noise_db: 背景（静かな窓の下位 10%）/ snr_db: 差
//   clip_ratio: 振幅が上限付近に張り付いた割合 / brightness: 高い音の成分の比（こもるほど小さい）
enum AudioQuality {
    static func measure(_ pcm: [Int16]) -> [String: Any] {
        let win = 480  // 30ms
        guard pcm.count > win * 4 else { return [:] }
        var rms: [Double] = []
        var i = 0
        while i + win <= pcm.count {
            var sum = 0.0
            for j in i..<i + win { let v = Double(pcm[j]); sum += v * v }
            rms.append((sum / Double(win)).squareRoot())
            i += win
        }
        let sorted = rms.sorted()
        let noise = max(sorted[sorted.count / 10], 1)
        let voiced = rms.filter { $0 > 330 }
        guard !voiced.isEmpty else { return [:] }
        let speech = voiced.reduce(0, +) / Double(voiced.count)
        func db(_ x: Double) -> Double { (20 * log10(x / 32768) * 10).rounded() / 10 }
        let clip = Double(pcm.filter { abs(Int($0)) >= 32000 }.count) / Double(pcm.count)
        var e = 0.0, d = 0.0
        for k in 1..<pcm.count { let a = Double(pcm[k]), b = Double(pcm[k - 1]); e += a * a; d += (a - b) * (a - b) }
        return [
            "level_db": db(speech), "noise_db": db(noise), "snr_db": ((20 * log10(speech / noise)) * 10).rounded() / 10,
            "clip_ratio": (clip * 10000).rounded() / 10000, "brightness": e > 0 ? ((d / e) * 1000).rounded() / 1000 : 0,
        ]
    }
}

// 録音元の共通インターフェース（既定のマイクは AVAudioEngine、指定したマイクは AVCaptureSession で開く）
protocol MicInput: AnyObject {
    var name: String { get }
    var deviceID: AudioDeviceID? { get }
    var onChunk: (([Int16], Int) -> Void)? { get set }
    var onConfigChange: (() -> Void)? { get set }
    var isRunning: Bool { get }
    func start() -> Bool
    func stop()
}

// 指定したマイクを AVCaptureSession で開き、16kHz mono Int16 で受け取る。
// AVAudioEngine でデバイスを指定すると、出力にも使われているデバイス（スピーカーフォン等）から音が来ないことがある
final class CaptureMic: NSObject, MicInput, AVCaptureAudioDataOutputSampleBufferDelegate {
    let name: String
    let deviceID: AudioDeviceID?
    var onChunk: (([Int16], Int) -> Void)?
    var onConfigChange: (() -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "koe.capture")
    private var observers: [Any] = []
    var isRunning: Bool { session.isRunning }

    init(deviceID: AudioDeviceID, name: String) {
        self.deviceID = deviceID
        self.name = name
    }

    private static func uid(of id: AudioDeviceID) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let st = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return st == 0 ? uid as String : nil
    }

    func start() -> Bool {
        guard let id = deviceID, let uid = CaptureMic.uid(of: id), let dev = AVCaptureDevice(uniqueID: uid),
              let input = try? AVCaptureDeviceInput(device: dev) else { return false }
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Recorder.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        for n in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: n, object: session, queue: .main) { [weak self] _ in self?.onConfigChange?() })
        }
        session.startRunning()
        return session.isRunning
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == 0,
              let ptr else { return }
        let count = length / MemoryLayout<Int16>.size
        let chunk = ptr.withMemoryRebound(to: Int16.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) }
        let peak = chunk.reduce(0) { max($0, abs(Int($1))) }
        onChunk?(chunk, peak)
    }
}

// 1 つの入力デバイスを開いて 16kHz mono に変換し続ける（既定のマイク用）
final class MicSource: MicInput {
    var isRunning: Bool { engine.isRunning }
    let engine = AVAudioEngine()
    let deviceID: AudioDeviceID?
    let name: String
    private var converter: AVAudioConverter?
    private let outFormat: AVAudioFormat
    private var configObserver: Any?
    var onChunk: (([Int16], Int) -> Void)?
    var onConfigChange: (() -> Void)?

    init(deviceID: AudioDeviceID?, name: String, outFormat: AVAudioFormat) {
        self.deviceID = deviceID
        self.name = name
        self.outFormat = outFormat
    }

    // Why the last start() returned false (#156: logged with the failed press instead of aborting)
    private(set) var lastFailure: MicTap.Failure?

    func start() -> Bool {
        lastFailure = nil
        let input = engine.inputNode
        if var id = deviceID, let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        // 入力デバイスが抜けた直後などは 0 ch / 0 Hz が返る。そのまま tap を入れると AVFAudio が例外を投げて落ちる
        let inFormat = input.outputFormat(forBus: 0)
        guard MicTap.isUsable(inFormat), let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            lastFailure = .formatInvalid
            return false
        }
        converter = conv
        input.removeTap(onBus: 0)
        if let f = MicTap.install(on: input, bufferSize: 1024, format: inFormat, block: { [weak self] buf, _ in self?.consume(buf) }) {
            lastFailure = f
            return false
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lastFailure = .engineStart
            return false
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.onConfigChange?()
        }
        return true
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func consume(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter else { return }
        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, let ch = out.int16ChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        let peak = chunk.reduce(0) { max($0, abs(Int($1))) }
        onChunk?(chunk, peak)
    }
}

final class Recorder {
    static let sampleRate = 16000.0
    let preRollSeconds = 0.5
    let tailSeconds = 0.25
    // 30ms 窓の RMS がこれを超えたら声とみなす（約 -40 dBFS）
    let voiceThreshold = 330.0
    // 部屋の雑音でも peak は数十ある。これ以下はミュート（本体で切られている）か入力停止
    let mutedPeak = 2

    // 1 つのマイクの録音バッファ
    final class Track {
        let source: MicInput
        var samples: [Int16] = []
        var preRoll: [Int16] = []
        var lastPeakAt = Date.distantPast
        init(_ s: MicInput) { source = s }
    }

    private let lock = NSLock()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Recorder.sampleRate,
                                          channels: 1, interleaved: true)!
    // tracks[0] が主のマイク。自動モードでは代わりのマイクも同時に開き、離した後に声が入っている方を使う
    private var tracks: [Track] = []
    private var primaryDeviceID: AudioDeviceID?
    private var recording = false
    private var lastBufferAt = Date.distantPast
    private var restartPending = false
    private(set) var warm = false
    var onRestart: ((String) -> Void)?
    var onSourceChange: ((String) -> Void)?

    private var dir: URL { WhisperServer.logURL.deletingLastPathComponent() }
    private var running: Bool { !tracks.isEmpty }

    var activeName: String {
        lock.lock(); defer { lock.unlock() }
        guard let p = tracks.first else { return "-" }
        return tracks.count > 1 ? "\(p.source.name)（ミュート中は \(tracks[1].source.name)）" : p.source.name
    }

    // 主のマイクが直近 1 秒ずっと無音ならミュート中とみなす（表示用）
    var primaryMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let p = tracks.first else { return false }
        return Date().timeIntervalSince(p.lastPeakAt) > 1.0
    }

    var fallbackName: String? {
        AudioDevices.fallback(excluding: primaryDeviceID ?? AudioDevices.defaultInput())?.name
    }

    // 主のマイク（選んだマイク、自動なら既定のマイク）の注意。録音していないときも今の設定で見る
    var notice: MicNotice.Kind? {
        guard Settings.micNotice else { return nil }
        let want = Settings.micName.flatMap { n in AudioDevices.selectable().first { $0.name == n } }
        let id = want?.id ?? AudioDevices.defaultInput()
        guard let d = want ?? AudioDevices.inputs().first(where: { $0.id == id }) else { return nil }
        return MicNotice.kind(transport: d.transport, lidClosed: MicNotice.lidClosed())
    }

    func reopen() {
        stopEngine()
        if warm { _ = startEngine() }
    }

    func setWarm(_ on: Bool) {
        warm = on
        if on { _ = startEngine() } else if !isRecording { stopEngine() }
    }

    private var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return recording }

    // Why the primary mic could not be opened on the last start() (device kind is logged with it)
    private(set) var lastStartFailure: MicTap.Failure?
    var primaryTransport: UInt32? {
        let id = primaryDeviceID ?? AudioDevices.defaultInput()
        return AudioDevices.inputs().first { $0.id == id }?.transport
    }

    private func open(_ deviceID: AudioDeviceID?, name: String, isPrimary: Bool) -> Track? {
        let src: MicInput = deviceID.map { CaptureMic(deviceID: $0, name: name) } ?? MicSource(deviceID: nil, name: name, outFormat: outFormat)
        let track = Track(src)
        src.onChunk = { [weak self, weak track] chunk, peak in
            guard let self, let track else { return }
            self.append(chunk, peak: peak, to: track)
        }
        src.onConfigChange = { [weak self, weak src] in
            guard let self, let src else { return }
            // 既定のマイクが変わった／エンジンが止まったときだけ張り直す（他のデバイスを開いた通知は無視）
            let defaultChanged = isPrimary && Settings.micName == nil && AudioDevices.defaultInput() != self.primaryDeviceID
            if !src.isRunning || defaultChanged { self.scheduleRestart(reason: "config_change") }
        }
        if src.start() { return track }
        if isPrimary { lastStartFailure = (src as? MicSource)?.lastFailure }
        return nil
    }

    private func startEngine() -> Bool {
        if running { return true }
        // マイクを選んでいればそれを、自動なら既定のマイクを使う
        let fixed = Settings.micName.flatMap { want in AudioDevices.selectable().first { $0.name == want } }
        let id = fixed?.id ?? AudioDevices.defaultInput()
        let name = fixed?.name ?? AudioDevices.inputs().first { $0.id == id }?.name ?? "default"
        primaryDeviceID = id
        lastStartFailure = nil
        // 既定のマイクはデバイスを指定せずに開く（指定すると構成変更の通知が出て張り直しが連鎖する）
        guard let primary = open(fixed?.id, name: name, isPrimary: true) else { return false }
        var list = [primary]
        if Settings.fallbackMic, fixed == nil, let dev = AudioDevices.fallback(excluding: id),
           let fb = open(dev.id, name: dev.name, isPrimary: false) {
            list.append(fb)
        }
        lock.lock()
        tracks = list
        lastBufferAt = Date()
        lock.unlock()
        onSourceChange?(activeName)
        return true
    }

    private func stopEngine() {
        lock.lock()
        let old = tracks
        tracks = []
        lock.unlock()
        old.forEach { $0.source.stop() }
    }

    private func scheduleRestart(reason: String) {
        guard !restartPending else { return }
        restartPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.restartPending = false
            self.restart(reason: reason)
        }
    }

    private func restart(reason: String) {
        stopEngine()
        if warm || isRecording { _ = startEngine() }
        onRestart?(reason)
    }

    private func append(_ chunk: [Int16], peak: Int, to track: Track) {
        lock.lock()
        defer { lock.unlock() }
        if track === tracks.first { lastBufferAt = Date() }
        if peak > mutedPeak { track.lastPeakAt = Date() }
        if recording {
            track.samples.append(contentsOf: chunk)
        } else {
            track.preRoll.append(contentsOf: chunk)
            let maxPre = Int(preRollSeconds * Recorder.sampleRate)
            if track.preRoll.count > maxPre { track.preRoll.removeFirst(track.preRoll.count - maxPre) }
        }
    }

    // 離した後の録り足し（tailSeconds）が終わっていない録音。この間に次の押下が来たら、先に確定させる
    private var pendingStop: (id: Int, done: (Capture) -> Void)?
    private var stopSeq = 0

    func start() -> Bool {
        // 前の録音の録り足し中に押された: 録り足しを切り上げて前の録音を先に確定する（以前はここで前の録音を消していた）
        if let p = pendingStop { pendingStop = nil; finalize(p.done) }
        // 主のマイクから 1 秒以上音が来ていなければエンジンが止まっているので張り直す
        lock.lock(); let stale = running && Date().timeIntervalSince(lastBufferAt) > 1.0; lock.unlock()
        if stale { restart(reason: "stalled") }
        if !startEngine() { return false }
        lock.lock()
        for t in tracks {
            t.samples = warm ? t.preRoll : []
            t.preRoll.removeAll()
        }
        recording = true
        lock.unlock()
        return true
    }

    func stop(_ done: @escaping (Capture) -> Void) {
        stopSeq += 1
        let id = stopSeq
        pendingStop = (id, done)
        DispatchQueue.main.asyncAfter(deadline: .now() + tailSeconds) {
            guard let p = self.pendingStop, p.id == id else { return }  // 次の押下で先に確定済み
            self.pendingStop = nil
            self.finalize(p.done)
        }
    }

    private func finalize(_ done: @escaping (Capture) -> Void) {
        do {
            self.lock.lock()
            self.recording = false
            let takes = self.tracks.map { ($0.source.name, $0.samples) }
            self.tracks.forEach { $0.samples.removeAll() }
            self.lock.unlock()
            if !self.warm { self.stopEngine() }
            // 主のマイクに声が入っていればそれを、なければ代わりのマイクを使う
            var chosen = takes.first ?? ("-", [])
            var trimmed = self.trimSilence(chosen.1)
            if trimmed.isEmpty, takes.count > 1 {
                let alt = self.trimSilence(takes[1].1)
                if !alt.isEmpty { chosen = takes[1]; trimmed = alt }
            }
            let captured = chosen.1
            let peak = captured.reduce(0) { max($0, abs(Int($1))) }
            // どのマイクも完全な無音ならエンジンが固まっている可能性。次に備えて張り直す
            let allSilent = takes.allSatisfy { $0.1.reduce(0) { max($0, abs(Int($1))) } <= self.mutedPeak }
            if allSilent && captured.count > Int(Recorder.sampleRate * 0.5) { self.restart(reason: "digital_silence") }
            let url = self.dir.appendingPathComponent("rec-\(UUID().uuidString).wav")
            self.writeWAV(trimmed.isEmpty ? captured : trimmed, to: url)
            // 各マイクから届いた量（比較用の録音が保存されないときの切り分け用）
            Events.log("tracks", ["tracks": takes.map { "\($0.0): \(String(format: "%.1f", Double($0.1.count) / Recorder.sampleRate))s peak \($0.1.reduce(0) { max($0, abs(Int($1))) })" }.joined(separator: " / ")])
            var cap = Capture(url: url, seconds: Double(captured.count) / Recorder.sampleRate,
                              voicedSeconds: Double(trimmed.count) / Recorder.sampleRate, peak: peak, device: chosen.0)
            cap.quality = AudioQuality.measure(captured)
            // 比較用に、使わなかった側のマイクの録音も残す（同じ発話のマイク違い）
            if Settings.saveAllMics, let other = takes.first(where: { $0.0 != chosen.0 }), !other.1.isEmpty {
                let altURL = self.dir.appendingPathComponent("rec-\(UUID().uuidString).alt.wav")
                self.writeWAV(other.1, to: altURL)
                cap.alt = (other.0, altURL, AudioQuality.measure(other.1))
            }
            done(cap)
        }
    }

    func discard() {
        lock.lock()
        recording = false
        tracks.forEach { $0.samples.removeAll() }
        lock.unlock()
        if !warm { stopEngine() }
    }

    private func trimSilence(_ pcm: [Int16]) -> [Int16] {
        let win = Int(Recorder.sampleRate * 0.03)
        guard pcm.count > win else { return [] }
        func loud(_ i: Int) -> Bool {
            let end = min(i + win, pcm.count)
            var sum = 0.0
            for j in i..<end { let v = Double(pcm[j]); sum += v * v }
            return (sum / Double(end - i)).squareRoot() > voiceThreshold
        }
        guard let first = stride(from: 0, to: pcm.count, by: win).first(where: loud),
              let last = stride(from: pcm.count - win, through: 0, by: -win).first(where: loud) else { return [] }
        let s = max(0, first - Int(Recorder.sampleRate * 0.25))
        let e = min(pcm.count, last + win + Int(Recorder.sampleRate * 0.3))
        return Array(pcm[s..<e])
    }

    private func writeWAV(_ pcm: [Int16], to url: URL) {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let dataSize = UInt32(pcm.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(Recorder.sampleRate)); u32(UInt32(Recorder.sampleRate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        try? d.write(to: url)
    }
}

// MARK: - LLM cleanup
//
// OpenAI 互換の chat/completions に投げて文字起こしを整形する。
// 既定は Ollama (localhost:11434)。LM Studio や LiteLLM にも同じ設定で向けられる。
// 失敗・タイムアウト時は呼び出し側で生の文字起こしにフォールバックする。

enum Cleaner {
    // 整形の指示は Resources/cleanup_prompt.txt（評価スクリプトと共用）
    static var systemPrompt: String {
        guard let url = Bundle.main.url(forResource: "cleanup_prompt", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    static func prompt() -> String {
        var p = systemPrompt
        let block = Glossary.llmBlock
        if !block.isEmpty {
            p += "\n\n以下は固有名詞・社内用語の一覧です（「表記 ← 読み・別名」）。音が近い語はこの表記に直してください。\n\(block)"
        }
        return p
    }

    static func clean(_ text: String, done: @escaping (Result<String, Error>) -> Void) {
        request(messages: [
            ["role": "system", "content": prompt()],
            ["role": "user", "content": "<transcript>\(text)</transcript>"],
        ], timeout: Settings.llmTimeout, done: done)
    }

    // モデルをメモリに載せておくための空打ち
    static func warmUp() {
        request(messages: [["role": "user", "content": "ok"]], timeout: 120, maxTokens: 1) { _ in }
    }

    private static func request(messages: [[String: String]], timeout: Double, maxTokens: Int? = nil,
                                done: @escaping (Result<String, Error>) -> Void) {
        guard let url = URL(string: Settings.llmEndpoint)?.appendingPathComponent("chat/completions") else {
            return done(.failure(NSError(domain: "Koe", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "LLM エンドポイントが不正です"])))
        }
        var body: [String: Any] = [
            "model": Settings.llmModel,
            "messages": messages,
            "temperature": 0,
            "stream": false,
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = Settings.llmAPIKey { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            if let error { return done(.failure(error)) }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                return done(.failure(NSError(domain: "Koe", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "LLM の応答を読めませんでした (HTTP \(code))"])))
            }
            // 思考モデルの <think> ブロックは捨てる
            let cleaned = content
                .replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            done(.success(cleaned))
        }.resume()
    }
}

// MARK: - History
//
// ~/Library/Application Support/Koe/history/YYYY-MM-DD/<id>.wav + <id>.json
// json の reference は空で保存し、評価時に正解テキストを入れる（eval/koe_eval.py）

enum History {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/history", isDirectory: true)
    }

    static func newID() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return f.string(from: Date())
    }

    // ② 直近 days 日の伝達判定（改善ループが付ける）
    // 直近 n 件の判定済みの発話で、誤解したまま作業が進んだ件数（misacted）と、言い直し・聞き返しが要った件数（redo）。
    // 件数で区切るのは、1 日 100 件程度だと偶然の揺れが大きいため
    static func communication(last n: Int = 300) -> (judged: Int, misacted: Int, redo: Int) {
        let fm = FileManager.default
        var files: [URL] = []
        for d in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().suffix(14) {
            let u = dir.appendingPathComponent(d)
            files += ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0.hasSuffix(".json") }.map { u.appendingPathComponent($0) }
        }
        var judged = 0, misacted = 0, redo = 0
        for url in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            guard judged < n, let data = try? Data(contentsOf: url),
                  let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let c = r["communication"] as? String, c != "unclear" else { continue }
            judged += 1
            if c == "corrected" {
                switch r["communication_impact"] as? String {
                case "misacted": misacted += 1
                case "redo": redo += 1
                default: break
                }
            }
        }
        return (judged, misacted, redo)
    }

    // 直近 n 件の貼り付けたテキスト（古い順）
    // 直近 n 件の記録（古い順）
    static func recentRecords(_ n: Int) -> [[String: Any]] {
        let fm = FileManager.default
        var files: [URL] = []
        for d in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().suffix(7) {
            let u = dir.appendingPathComponent(d)
            files += ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0.hasSuffix(".json") }.map { u.appendingPathComponent($0) }
        }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(n).compactMap {
            (try? Data(contentsOf: $0)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    static func recentPasted(_ n: Int) -> [(time: Date, text: String)] {
        let fm = FileManager.default
        let days = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().suffix(3)
        var files: [URL] = []
        for d in days {
            let u = dir.appendingPathComponent(d)
            files += ((try? fm.contentsOfDirectory(atPath: u.path)) ?? []).filter { $0.hasSuffix(".json") }.map { u.appendingPathComponent($0) }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }.suffix(n * 2).compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = r["pasted"] as? String, !text.isEmpty,
                  let id = r["id"] as? String, let t = f.date(from: id) else { return nil }
            return (t, text)
        }.suffix(n).map { $0 }
    }

    static func save(id: String, wav: URL, record: [String: Any], alt: URL? = nil) {
        let day = dir.appendingPathComponent(String(id.prefix(10)), isDirectory: true)
        try? FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        var rec = record
        if let alt {
            try? FileManager.default.moveItem(at: alt, to: day.appendingPathComponent("\(id).alt.wav"))
            rec["alt_audio"] = "\(id).alt.wav"
        }
        rec["id"] = id
        rec["audio"] = "\(id).wav"
        rec["reference"] = NSNull()
        try? FileManager.default.moveItem(at: wav, to: day.appendingPathComponent("\(id).wav"))
        if let data = try? JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: day.appendingPathComponent("\(id).json"))
        }
    }

    // 保存済みの記録に欄を書き足す
    static func merge(id: String, _ fields: [String: Any]) {
        let url = dir.appendingPathComponent(String(id.prefix(10)), isDirectory: true).appendingPathComponent("\(id).json")
        guard let data = try? Data(contentsOf: url),
              var rec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        rec.merge(fields) { _, b in b }
        if let out = try? JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: url)
        }
    }
}

// MARK: - Improvement loop
//
// 使うほど良くなる仕組み。新しい発話が improveBatch 件たまったら、録音していないときに動く。
// 1. Claude Code のセッション記録（~/.claude/projects）から、発話ごとに「実際に送った文・Claude の返答・次の発話」を引く
// 2. OpenAI 互換の LLM に渡し、誤変換された語（→正しい表記）と伝達の判定を JSON で受け取る
// 3. 語は 2 回以上（本人の明示的な訂正なら 1 回）出てきたら、誤変換された形を別名にして個人の辞書に足す
// 4. 伝達の判定は履歴の json に書く（koe_eval.py trend で推移を見る）
// 発話は improveEndpoint にだけ送る。既定はオフ。

enum SessionLog {
    struct Human { let time: Date; let text: String; let reply: String; let next: String }

    private static func text(of content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            if arr.contains(where: { $0["type"] as? String == "tool_result" }) { return "" }
            return arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // since 以降に更新されたセッション記録から、人の発話と直後の返答・次の発話を取り出す
    static func load(since: Date) -> [Human] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let fm = FileManager.default
        var out: [Human] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                guard m >= since, let data = try? String(contentsOf: f, encoding: .utf8) else { continue }
                // (時刻, 種類, テキスト)。種類 0=Claude の返答 1=入力欄から送った発話 2=Claude の作業中に送った発話（キュー）
                var events: [(Date, Int, String)] = []
                for line in data.split(separator: "\n") {
                    guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let type = d["type"] as? String, let ts = d["timestamp"] as? String,
                          let t = iso.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) else { continue }
                    if type == "queue-operation" {
                        if d["operation"] as? String == "enqueue", let c = d["content"] as? String, !c.isEmpty { events.append((t, 2, c)) }
                    } else if type == "user" {
                        let s = text(of: (d["message"] as? [String: Any])?["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty, !s.hasPrefix("<"), !s.hasPrefix("Another Claude session"), d["isMeta"] as? Bool != true { events.append((t, 1, s)) }
                    } else if type == "assistant" {
                        let s = text(of: (d["message"] as? [String: Any])?["content"])
                        if !s.isEmpty { events.append((t, 0, s)) }
                    }
                }
                // 返答は、次に入力欄から送るまでの Claude の発言を全部（作業中に送った発話はまたぐ）
                for (i, e) in events.enumerated() where e.1 != 0 && e.0 >= since {
                    var reply = "", next = ""
                    for e2 in events[(i + 1)...] {
                        if e2.1 != 0, next.isEmpty { next = e2.2 }
                        if e2.1 == 1 { break }
                        if e2.1 == 0 { reply += e2.2 + "\n" }
                    }
                    out.append(Human(time: e.0, text: e.2, reply: String(reply.prefix(400)), next: String(next.prefix(200))))
                }
            }
        }
        return out
    }

    static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) })
    }

    // 発話の時刻から 20 秒以内（貼り付けは数秒で届く。広げると手で貼り直した発言と誤一致する）に、同じ文面（先頭か末尾の 12 文字が含まれる）で送られた人の発話
    static func match(_ text: String, at time: Date, in humans: [Human]) -> Human? {
        let n = normalize(text)
        guard n.count >= 4 else { return nil }
        let head = String(n.prefix(12)), tail = String(n.suffix(12))
        return humans.first { h in
            h.time >= time.addingTimeInterval(-5) && h.time <= time.addingTimeInterval(20)
                && { let s = normalize(h.text); return s.contains(head) || s.contains(tail) }()
        }
    }
}

final class Improver {
    private(set) var running = false
    private(set) var lastRun: String?
    var onFinish: ((String) -> Void)?

    private var koeDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe")
    }

    // 改善に使っていない発話（直近 7 日）。judgeOnly のときは、語は拾ったが伝達の判定が付いていない発話（判定を 2 回まで試す）
    private func unscanned(judgeOnly: Bool = false) -> [(URL, [String: Any])] {
        let fm = FileManager.default
        let hist = History.dir
        let days = ((try? fm.contentsOfDirectory(atPath: hist.path)) ?? []).sorted().suffix(7)
        var out: [(URL, [String: Any])] = []
        for d in days {
            let dir = hist.appendingPathComponent(d)
            for f in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where f.hasSuffix(".json") {
                let url = dir.appendingPathComponent(f)
                guard let data = try? Data(contentsOf: url),
                      let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      r["dropped"] as? Bool != true,
                      // ロック録音（1on1 のメモ等。相手の声も入る）は改善ループに送らない
                      r["locked"] as? Bool != true,
                      let raw = r["raw"] as? String, !raw.isEmpty else { continue }
                if judgeOnly {
                    guard r["glossary_scanned"] as? Bool == true, r["communication"] == nil, r["pasted"] is String,
                          (r["judge_attempts"] as? Int ?? 0) < 2 else { continue }
                } else if r["glossary_scanned"] as? Bool == true { continue }
                out.append((url, r))
            }
        }
        return out
    }

    var pendingCount: Int { unscanned().count }

    func runIfNeeded(force: Bool = false) {
        guard Settings.improveEnabled, !running else { return }
        if Settings.improveProvider == "api" && Settings.improveEndpoint.isEmpty { return }
        PeopleStore.refresh()  // 起動しっぱなしでも 1 日 1 回は取り直す（新しければ何もしない）
        var items = unscanned()
        var judgeOnly = false
        if !(force ? !items.isEmpty : items.count >= Settings.improveBatch) {
            // 新しい発話が溜まっていなければ、判定が抜けた発話を判定だけやり直す
            items = unscanned(judgeOnly: true)
            judgeOnly = true
            guard !items.isEmpty else { return }
        }
        running = true
        let batch = judgeOnly ? Array(items.suffix(30)) : Array(items.suffix(60))
        DispatchQueue.global(qos: .utility).async {
            let summary: String
            do { summary = try self.run(batch, judgeOnly: judgeOnly) } catch { summary = "失敗: \(error.localizedDescription)" }
            DispatchQueue.main.async {
                self.running = false
                self.lastRun = summary
                Events.log("improve", ["summary": summary])
                self.onFinish?(summary)
            }
        }
    }

    private static let idFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss-SSS"
        return f
    }()

    private func run(_ items: [(URL, [String: Any])], judgeOnly: Bool = false) throws -> String {
        let times = items.compactMap { ($0.1["id"] as? String).flatMap { Improver.idFormat.date(from: $0) } }
        let humans = SessionLog.load(since: (times.min() ?? Date()).addingTimeInterval(-3600))
        var lines: [String] = []
        var replyOwner: [String: Int] = [:]
        // 人の名前を辞書に足すかの判定（People.judge）に使う、発話ごとの文字起こしと前後
        var transcripts: [Int: String] = [:], contexts: [Int: String] = [:]
        for (i, (_, r)) in items.enumerated() {
            let raw = r["raw"] as? String ?? ""
            transcripts[i] = raw
            var line = "[\(i)] 文字起こし: \(raw)"
            if let t = (r["id"] as? String).flatMap({ Improver.idFormat.date(from: $0) }),
               let h = SessionLog.match(r["pasted"] as? String ?? raw, at: t, in: humans) {
                contexts[i] = [h.text, h.reply, h.next].joined(separator: "\n")
                if SessionLog.normalize(h.text) != SessionLog.normalize(raw) { line += "\n  実際に送った文: \(h.text.prefix(300))" }
                if h.reply.isEmpty {
                    line += "\n  Claude の返答: （なし。次の発話が先に入った）"
                } else if let j = replyOwner[h.reply] {
                    line += "\n  Claude の返答: （[\(j)] と同じ返答。Claude の作業中に続けて送った発話で、まとめて 1 つの返答になっている）"
                } else {
                    replyOwner[h.reply] = i
                    line += "\n  Claude の返答: \(h.reply)"
                }
                line += "\n  次の発話: \(h.next.isEmpty ? "（なし）" : h.next)"
            } else {
                line += "\n  （Claude Code のセッション記録なし）"
            }
            lines.append(line)
        }
        let known = (Glossary.personal + Glossary.org).map(\.term).prefix(400).joined(separator: "、")
        // 社員名簿（peopleSources を設定したときだけ）は毎回全員分を渡す。人の名前の化けを、名簿の誰かに結びつけるため
        let people = PeopleStore.all
        let system = Improver.prompt + (people.isEmpty ? "" : Improver.peoplePrompt)
        var user = "既に辞書にある語: \(known)\n\n"
        if !people.isEmpty { user += "社員名簿（ID<TAB>本名、\(people.count) 人）:\n\(People.promptBlock(people))\n\n" }
        user += lines.joined(separator: "\n\n")
        func ask() throws -> [String: Any] {
            let content = Settings.improveProvider == "api"
                ? try LLM.chat(endpoint: Settings.improveEndpoint, model: Settings.improveModel, auth: Settings.improveAuth(),
                               system: system, user: user, timeout: 180)
                : try LLM.command(Settings.improveCommand, prompt: system + "\n\n---\n\n" + user, timeout: 300)
            // 解析に失敗したときの調査用に、直近の応答をローカルに残す
            try? content.write(to: koeDir.appendingPathComponent("improve_last_response.txt"), atomically: true, encoding: .utf8)
            guard let s = content.firstIndex(of: "{"), let e = content.lastIndex(of: "}"),
                  let json = try? JSONSerialization.jsonObject(with: Data(content[s...e].utf8)) as? [String: Any] else {
                throw NSError(domain: "Koe", code: 20, userInfo: [NSLocalizedDescriptionKey: "改善ループの応答を読めませんでした"])
            }
            return json
        }
        // LLM が judgements を丸ごと省くことがある。1 回だけ聞き直し、それでも無ければ処理済みにせず次回に回す
        var json = try ask()
        if (json["judgements"] as? [Any])?.isEmpty ?? true { json = try ask() }
        if (json["judgements"] as? [Any])?.isEmpty ?? true {
            if judgeOnly {
                for (url, r) in items {
                    var rec = r
                    rec["judge_attempts"] = (r["judge_attempts"] as? Int ?? 0) + 1
                    if let data = try? JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
                }
            }
            throw NSError(domain: "Koe", code: 21, userInfo: [NSLocalizedDescriptionKey: "改善ループの応答に伝達の判定がありませんでした（次回やり直す）"])
        }
        // 伝達の判定を履歴に書く
        var judged = 0, failed = 0
        let judgements = json["judgements"] as? [[String: Any]] ?? []
        var byIndex: [Int: [String: Any]] = [:]
        for j in judgements { if let i = j["i"] as? Int { byIndex[i] = j } }
        for (i, (url, r)) in items.enumerated() {
            var rec = r
            if let j = byIndex[i], let label = Improver.label(j) {
                rec["communication"] = label
                rec["communication_note"] = j["reason"] as? String ?? ""
                // 伝わらなかったときの困り具合: misacted＝誤解したまま作業が進んだ / redo＝言い直し・聞き返しが要った / dropped＝一部が落ちたが言い直さずに進んだ
                if label == "corrected" { rec["communication_impact"] = (j["impact"] as? String).flatMap { ["misacted", "redo", "dropped"].contains($0) ? $0 : nil } ?? "redo" }
                else { rec.removeValue(forKey: "communication_impact") }
                judged += 1
                if label == "corrected" { failed += 1 }
            }
            rec["glossary_scanned"] = true
            if judgeOnly { rec["judge_attempts"] = (r["judge_attempts"] as? Int ?? 0) + 1 }
            if let data = try? JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
        }
        // 語を候補に積み、条件を満たしたら個人の辞書へ（判定のやり直しでは、語は前回数えたので数えない）
        if judgeOnly { return "判定のやり直し \(items.count) 件（判定 \(judged)、伝わらなかった \(failed)）" }
        let added = mergeTerms(json["terms"] as? [[String: Any]] ?? [], people: people, transcripts: transcripts, contexts: contexts)
        if !people.isEmpty {
            let called = (json["people"] as? [[String: Any]] ?? []).compactMap { x -> (who: String, called: String)? in
                guard let c = x["called"] as? String, let w = x["who"] as? String, let i = x["i"] as? Int, let t = transcripts[i] else { return nil }
                return People.judgeCalled(.init(called: c, who: w, confidence: x["confidence"] as? String, transcript: t), people: people)
            }
            PeopleStore.remember(called: called, wrongs: [])
            if !called.isEmpty { Glossary.exportForReceivers() }
        }
        return "\(items.count) 件を処理（判定 \(judged)、伝わらなかった \(failed)）。辞書に追加: \(added.isEmpty ? "なし" : added.joined(separator: "、"))"
    }

    // ラベルは LLM に直接選ばせず、段階ごとの答えから決める（LLM は「読み替えた」と書きながら corrected を付けがち）
    static func label(_ j: [String: Any]) -> String? {
        if j["unknown"] as? Bool == true { return "unclear" }
        if let err = j["error"] as? Bool {
            if !err { return "understood" }
            return j["read_ok"] as? Bool == true ? "understood" : "corrected"
        }
        if let l = j["label"] as? String, ["understood", "corrected", "unclear"].contains(l) { return l }
        return nil
    }
    // 辞書に入れてよい「語」か。句（助詞を含む）や、ひらがな・漢字だけの普通の言葉は入れない（人名は除く）
    static func isTerm(_ w: String, person: Bool) -> Bool {
        guard (2...20).contains(w.count) else { return false }
        if person { return true }
        let hasKanaOrLatin = w.unicodeScalars.contains { (0x30A0...0x30FF).contains($0.value) || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
        if !hasKanaOrLatin { return false }
        // カタカナ・英字を含んでも、助詞でつながった句は入れない（「新社Slackの一本化」「①の恒久対応」）
        for p in ["の", "を", "が", "は", "に", "で", "と", "へ", "から", "まで"] where w.contains(p) {
            // カタカナ語の中の「ノ」等ではなく、ひらがなの助詞のとき
            return false
        }
        return true
    }

    private func mergeTerms(_ terms: [[String: Any]], people: [People.Person] = [], transcripts: [Int: String] = [:],
                            contexts: [Int: String] = [:]) -> [String] {
        let candURL = koeDir.appendingPathComponent("glossary_candidates.json")
        var cand = (try? JSONSerialization.jsonObject(with: Data(contentsOf: candURL))) as? [String: [String: Any]] ?? [:]
        var promote: [String: [String]] = [:]
        var learned: [(who: String, called: String)] = [], learnedWrongs: [(who: String, wrong: String)] = []
        let knownCalled = people.isEmpty ? [:] : PeopleStore.known().called
        for var t in terms {
            // 近い読みの形は People.judge の守りを通したものだけ使う（人の名前でない語に付いてきたものは捨てる）
            let raw = t.removeValue(forKey: "variants") as? [String] ?? []
            // 人の名前・呼び名（名簿にある名前を kind: "term" で返したものも）は、文字起こしと前後から確かなときだけ足す（People.judge）
            if t["kind"] as? String == "person" || People.isPersonName(t["right"] as? String ?? "", people) {
                let wrong = t["wrong"] as? String ?? ""
                let core = People.splitHonorific(wrong).core
                // 発話の番号が無い・合わないときは、化けた形を含む発話を探す
                let i = (t["i"] as? Int).flatMap { transcripts[$0]?.contains(core) == true ? $0 : nil }
                    ?? transcripts.keys.sorted().first { !core.isEmpty && transcripts[$0]!.contains(core) }
                let d = People.judge(.init(wrong: wrong, right: t["right"] as? String ?? "", who: t["who"] as? String,
                                           explicit: t["explicit"] as? Bool == true, confidence: t["confidence"] as? String,
                                           transcript: i.flatMap { transcripts[$0] } ?? "", context: i.flatMap { contexts[$0] } ?? "",
                                           variants: raw),
                                     people: people, knownCalled: knownCalled)
                guard case .add(let a) = d else { continue }
                t = ["wrong": a.alias, "right": a.term, "kind": "person", "explicit": t["explicit"] as? Bool == true, "variants": a.variants]
                if let who = a.who {
                    learned.append((who, a.called))
                    learnedWrongs += ([a.alias] + a.variants).map { (who, $0.replacingOccurrences(of: ">", with: "")) }
                }
            }
            guard let right = (t["right"] as? String)?.trimmingCharacters(in: .whitespaces), (2...30).contains(right.count),
                  let wrong = (t["wrong"] as? String)?.trimmingCharacters(in: .whitespaces), !wrong.isEmpty, wrong != right,
                  // 語ではなく文・注記になっているもの（「(聞き取り不能)」「〜、〜のやつ」）は辞書に入れない
                  wrong.count <= 15, !wrong.contains("、"), !right.contains("("), !right.contains("（"),
                  Improver.isTerm(right, person: t["kind"] as? String == "person") else { continue }
            var c = cand[right] ?? ["count": 0, "wrongs": [String]()]
            // 人の名前・呼び名は個人の辞書にだけ使い、共有パックへの提案には回さない印
            if t["kind"] as? String == "person" { c["person"] = true }
            c["count"] = (c["count"] as? Int ?? 0) + 1
            var wrongs = c["wrongs"] as? [String] ?? []
            // 人の名前は、近い読みの形（People.judge が守りを通したもの）も一緒に別名にする
            for w in [wrong] + (t["variants"] as? [String] ?? []) where !wrongs.contains(w) { wrongs.append(w) }
            c["wrongs"] = wrongs
            if t["explicit"] as? Bool == true { c["explicit"] = true }
            cand[right] = c
            // 本人が正しい表記を示した語は確かな置き換え、回数だけで上げた語は「~」（受け取る AI へのメモだけ。勝手に置き換えない）。
            let sure = c["explicit"] as? Bool == true
            // 人の名前で「化けた形>敬称」の別名は、敬称が続くときだけ置き換わる（「パン粉を買う」は変わらない）ので、
            // 確かに検出した 1 回目で辞書に上げて置き換えてよい（出現が少ない名前は 2 回を待つと覚えきれない。IMP-8）
            let anchored = c["person"] as? Bool == true && wrongs.allSatisfy { $0.contains(">") }
            // ひらがな・漢字だけの形（「かぶる」等）や 3 文字以下は普通の言葉と重なりやすいので、明示されても勝手に置き換えない
            func common(_ w: String) -> Bool {
                w.count <= 3 || !w.unicodeScalars.contains { (0x30A0...0x30FF).contains($0.value) || CharacterSet.letters.contains($0) && $0.isASCII }
            }
            // 人の名前の、敬称の条件が無い別名は置き換えない（受け取る AI へのメモだけ）
            let person = c["person"] as? Bool == true
            if (c["count"] as? Int ?? 0) >= 2 || sure || anchored {
                promote[right] = wrongs.map { (sure || anchored) && !common($0) && (!person || $0.contains(">")) ? $0 : "~" + $0 }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: cand, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: candURL) }
        PeopleStore.remember(called: learned, wrongs: learnedWrongs)
        guard !promote.isEmpty else { return [] }
        // 個人の辞書を更新（既にある語は別名を足す。上限 300 語。whisper に渡すのは最近使った語だけなので、辞書は大きくてよい）
        let path = (Settings.glossaryPath as NSString).expandingTildeInPath
        var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "# Koe 個人の辞書（改善ループが自動で育てる。不要な語は消してよい）\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var added: [String] = []
        for (term, wrongs) in promote {
            if let i = lines.firstIndex(where: { $0.split(separator: "\t").first.map(String.init)?.trimmingCharacters(in: .whitespaces) == term }) {
                let e = Glossary.parse(lines[i]).first
                let merged = Array(Set((e?.aliases ?? []) + wrongs)).sorted()
                lines[i] = term + "\t" + merged.joined(separator: "／")
            } else if Glossary.personal.count + added.count < 300 {
                lines.insert(term + "\t" + wrongs.joined(separator: "／"), at: min(1, lines.count))
                added.append(term)
            }
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        Glossary.exportForReceivers()
        return added
    }

    static let prompt = """
    あなたは音声入力アプリの改善係です。音声認識（whisper）で文字起こしして AI エージェント（Claude Code 等）に送った発話の一覧が渡されます。各発話には、分かる場合は実際に送った文・Claude の返答・本人の次の発話が付いています。
    次の 2 つを JSON だけで返してください。

    1. terms: 誤変換された語と正しい表記
       - 技術用語・英字略語・サービス名・社内用語・プロダクト名、人の名前・呼び名（ハンドル名・あだ名）が対象
       - 1 つの語だけ。句や言い回し（「〜の〜」「〜を〜する」）、普通の日本語の言葉（「遅延」「返事不要」等）、文の一部は出さない
       - 人の名前・呼び名には kind: "person"、それ以外は kind: "term" を付ける（人の名前は本人の Mac の個人の辞書にだけ入り、共有されない）
       - 人の名前は、普通の言葉と取り違えやすい（「パン粉を買う」の「パン粉」は人ではない）。「〜さん」などの敬称が付き、前後に人とのやりとり（Slack・レビュー・PR・会議など）がある場合だけ出す。wrong は敬称つきで書く（例: "パン粉さん"）
       - 人の名前の right は、本人が言った呼び方の正しい表記にする。わざと言ったあだ名・ハンドル名を本名に書き換えない
       - 人の名前の term には、同じ名前が化けそうな近い読みの形を variants に最大 5 つ付ける（例: right が "panko" で wrong が "パン粉さん" なら ["パンコ", "パンコア", "バンコ"]）。敬称は付けない。正しい表記そのもの・その人のほかの正しい呼び方やあだ名は入れない。思いつかなければ空の配列
       - 各 term に、その語が出てきた発話の番号 i と、確度 confidence（"high" / "medium" / "low"）を付ける。人の名前は "high" のときだけ辞書に入る
       - wrong は文字起こしに実際に含まれる文字列。right は正しい表記（2〜30 文字）
       - 本人の次の発話や送った文の手直しで正しい表記が明示されているか、Claude が「〜と読みました」「〜のことですか？」と読み替えて本人が否定していなければ explicit: true
       - 確信がなければ出さない。既に辞書にある語でも、新しい誤変換の形が見つかれば出す
    2. judgements: 各発話について、次の 3 つに true / false で答える
       - error: 文字起こしに、意味を変える誤り（誤変換・欠け・幻聴の繰り返し）があるか。Claude の答えの良し悪し・本人の反論や不満は関係ない
       - read_ok: error が true のとき、Claude が正しい意味に読み替えて応じたか（「〜と読み替えました」と添えた場合も true）。違う意味で動いた／意味を確認する質問をした／その部分を無視した／本人が誤った語を言い直した、なら false
       - impact: read_ok が false のときだけ、困り具合を 1 つ選ぶ
         - "misacted": Claude が誤った意味のまま作業を進めた（違うファイルを直した・違うコマンドを実行した・違う内容で文書を書いた等）
         - "redo": Claude が聞き返した、または答えが噛み合わず本人が言い直した・聞き直した
         - "dropped": 誤った部分を Claude が飛ばしたが、本人は言い直さずに話が進んだ
       - unknown: 返答も次の発話もなく判断できないときだけ true。返答が（なし）で、次の発話が同じ内容の言い直しでもないときも true
       - 「[n] と同じ返答」の発話は、まとめた返答がその発話の内容にも触れていれば read_ok: true。触れていなくても、誤りのせいだと言えなければ unknown: true
       - reason は 30 文字以内。発話の本文は写さない
       - judgements は、すべての発話 [0]〜[最後] について 1 件ずつ必ず出す（terms が空でも省かない）

    {"terms": [{"i": 0, "wrong": "...", "right": "...", "kind": "term", "explicit": false, "confidence": "high"}, {"i": 1, "wrong": "...さん", "right": "...", "kind": "person", "explicit": false, "confidence": "high", "variants": ["...", "..."]}], "judgements": [{"i": 0, "error": false, "read_ok": true, "impact": null, "unknown": false, "reason": "..."}]}
    """

    // 社員名簿を渡すときだけ足す指示
    static let peoplePrompt = """

    社員名簿（ID<TAB>本名）も渡します。人の名前・呼び名については次も答えてください。
    - terms の kind: "person" には、名簿の誰のことかを who に ID で書く（分からなければ who を付けない）。音の近い ID・本名・呼び方から判断する
    - 3. people: 化けずに正しく文字になった呼び方・あだ名が、名簿の誰のことか確かに分かるとき（例: 「〜さん」に Slack・レビュー・PR の話が続く）だけ、{"i": 発話の番号, "called": "呼び方（敬称なし）", "who": "ID", "confidence": "high"} を出す。あだ名を本名に書き換えない
    - 名簿に無い人や、人の名前か普通の言葉か迷う語は出さない

    terms の kind: "person" には "who": "ID" を足し、返す JSON に "people": [{"i": 0, "called": "...", "who": "...", "confidence": "high"}] を足す（無ければ空の配列）。
    """
}

// OpenAI 互換の chat/completions、またはコマンド（標準入力→標準出力）を同期で呼ぶ（バックグラウンドから使う）
enum LLM {
    static func command(_ cmd: String, prompt: String, timeout: Double) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]  // ログインシェルで PATH を通す（claude などは ~/.local/bin にある）
        let input = Pipe(), output = Pipe(), errput = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errput
        try p.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(timeout)
        var out = Data()
        let reader = DispatchQueue(label: "koe.llm.read")
        let sem = DispatchSemaphore(value: 0)
        reader.async { out = output.fileHandleForReading.readDataToEndOfFile(); sem.signal() }
        if sem.wait(timeout: .now() + max(1, deadline.timeIntervalSinceNow)) == .timedOut {
            p.terminate()
            throw NSError(domain: "Koe", code: 25, userInfo: [NSLocalizedDescriptionKey: "コマンドがタイムアウトしました: \(cmd)"])
        }
        p.waitUntilExit()
        let text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard p.terminationStatus == 0, !text.isEmpty else {
            let err = String(data: errput.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "Koe", code: 26, userInfo: [NSLocalizedDescriptionKey: "コマンドが失敗しました（\(p.terminationStatus)）: \(err.prefix(200))"])
        }
        return text
    }

    static func chat(endpoint: String, model: String, auth: String?, system: String, user: String, timeout: Double) throws -> String {
        guard let url = URL(string: endpoint)?.appendingPathComponent("chat/completions") else {
            throw NSError(domain: "Koe", code: 21, userInfo: [NSLocalizedDescriptionKey: "エンドポイントが不正です"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "temperature": 0, "max_tokens": 16000, "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ])
        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(NSError(domain: "Koe", code: 22))
        URLSession.shared.dataTask(with: req) { data, resp, error in
            defer { sem.signal() }
            if let error { result = .failure(error); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                result = .failure(NSError(domain: "Koe", code: 23, userInfo: [NSLocalizedDescriptionKey: "LLM の応答を読めませんでした (HTTP \(code))"]))
                return
            }
            if content.isEmpty {
                let reason = (json["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String ?? "?"
                result = .failure(NSError(domain: "Koe", code: 24, userInfo: [NSLocalizedDescriptionKey: "LLM の応答が空でした（finish_reason: \(reason)）"]))
                return
            }
            result = .success(content)
        }.resume()
        sem.wait()
        return try result.get()
    }
}

// MARK: - Config import
//
// 配布用の設定ファイル（JSON）を読み込む。組織の辞書・改善ループや整形の LLM の接続先をまとめて配れる。
// orgGlossary が相対パスなら設定ファイルからの相対で解決し、Application Support にコピーして使う。
// MDM の構成プロファイルで同じキーを配ってもよい（UserDefaults の管理対象として効く）。

enum ConfigImport {
    static let keys: [(key: String, label: String)] = [
        ("orgGlossary", "組織の辞書"),
        ("improveProvider", "改善ループの方式（command / api）"), ("improveCommand", "改善ループのコマンド"),
        ("improveEndpoint", "改善ループの送り先"), ("improveModel", "改善ループのモデル"),
        ("improveAPIKey", "改善ループの API キー"), ("improveTokenCommand", "改善ループのトークン取得コマンド"),
        ("improveEnabled", "改善ループを有効にする"), ("improveBatch", "改善ループの件数"),
        ("llmEndpoint", "整形の送り先"), ("llmModel", "整形のモデル"), ("llmAPIKey", "整形の API キー"), ("llmEnabled", "整形を有効にする"),
        ("hotkeyKeyCode", "ホットキー"), ("language", "言語"), ("audioCtx", "文字起こしの窓（auto / 0 = 全体）"),
        ("packFiles", "取り込む用語パック"), ("enabledPacks", "有効にする用語パック"),
        ("packSources", "共有の用語パックの取り込み元（gh:… / https:…）"),
        ("peopleSources", "社員名簿の取り込み元（gh:… / https:…。改善ループに渡す）"),
    ]

    static func run() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Koe の設定ファイル（JSON）を選んでください"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try apply(from: url) } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }

    static func apply(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard var cfg = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Koe", code: 40, userInfo: [NSLocalizedDescriptionKey: "設定ファイルが JSON のオブジェクトではありません"])
        }
        let known = Set(keys.map(\.key))
        let unknown = cfg.keys.filter { !known.contains($0) }.sorted()
        cfg = cfg.filter { known.contains($0.key) }
        // 組織の辞書が相対パスなら、設定ファイルと同じフォルダから取り込む
        var glossaryFile: URL?
        if let g = cfg["orgGlossary"] as? String, !g.hasPrefix("http"), !g.hasPrefix("/"), !g.hasPrefix("~") {
            glossaryFile = url.deletingLastPathComponent().appendingPathComponent(g)
        }
        var lines: [String] = []
        for (key, label) in keys {
            guard let v = cfg[key] else { continue }
            let shown = key.hasSuffix("APIKey") ? "（設定あり・非表示）" : "\(v)"
            lines.append("・\(label): \(shown)")
        }
        let a = NSAlert()
        a.messageText = "この設定を読み込みますか？"
        var info = lines.joined(separator: "\n")
        if let cmd = cfg["improveTokenCommand"] as? String, !cmd.isEmpty {
            info += "\n\n⚠️ トークン取得コマンドは、この Mac 上でそのまま実行されます。配布元を信頼できる場合だけ読み込んでください:\n\(cmd)"
        }
        if let cmd = cfg["improveCommand"] as? String, !cmd.isEmpty {
            info += "\n\n⚠️ 改善ループのコマンドは、この Mac 上でそのまま実行されます:\n\(cmd)"
        }
        if cfg["improveEnabled"] as? Bool == true {
            info += "\n\n⚠️ 改善ループが有効になり、発話の文字起こしとセッション記録の該当部分が送られます。"
        }
        if !unknown.isEmpty { info += "\n\n（使わないキー: \(unknown.joined(separator: ", "))）" }
        a.informativeText = info
        a.addButton(withTitle: "読み込む")
        a.addButton(withTitle: "やめる")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        // 用語パック（設定ファイルからの相対パス）を Application Support/Koe/packs に取り込む
        if let files = cfg["packFiles"] as? [String] {
            let packsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe/packs")
            try FileManager.default.createDirectory(at: packsDir, withIntermediateDirectories: true)
            for f in files {
                let src = url.deletingLastPathComponent().appendingPathComponent(f)
                let dest = packsDir.appendingPathComponent(src.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: src, to: dest)
            }
            cfg.removeValue(forKey: "packFiles")
        }
        if let src = glossaryFile {
            let dest = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Koe/org_glossary.txt")
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
            cfg["orgGlossary"] = dest.path
        }
        for (k, v) in cfg { UserDefaults.standard.set(v, forKey: k) }
        Glossary.refreshOrgIfNeeded()
        Glossary.refreshPackSources(force: true)
        PeopleStore.refresh(force: true)
        Glossary.exportForReceivers()
        Events.log("config_imported", ["keys": cfg.keys.sorted().joined(separator: ",")])
    }
}

// MARK: - Typing into the frontmost app

enum Typist {
    // 貼った文を TUI が取り込み終える前に Enter が来ると、Enter が貼り付けの一部（改行）として吸われる。
    // 取り込みにかかる時間は文の長さと Mac の負荷で伸びる（負荷 40〜60 で 0.8 秒でも間に合わなかった）ので、両方に合わせて待つ。最大 2 秒
    static func enterDelay(chars: Int) -> Double {
        var load = [Double](repeating: 0, count: 3)
        let l = getloadavg(&load, 3) > 0 ? load[0] : 0
        let base = 0.25 + min(0.25, Double(chars) / 400)
        return min(2.0, base * (1 + max(0, l - 4) / 10))
    }

    // ⌘V を送った時刻を返す（paste_at。画面に出た・Claude Code に届いたまでの時間の起点）
    @discardableResult
    // targetPID: 貼る先のアプリ（前に戻した直後は frontmostApplication がまだ古いことがあるので、分かっていれば渡す）
    static func pasteAndMaybeEnter(_ text: String, enter: Bool, targetPID: pid_t? = nil) -> Date {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        postKey(9, flags: .maskCommand) // ⌘V
        let pastedAt = Date()
        if enter {
            // 貼り付け直後の Enter は TUI 側で貼り付けの一部として扱われることがあるので少し待つ。
            // Mac が重いと貼り付けの取り込みが遅れ、0.25 秒では Enter が貼り付けに吸われる（負荷 20 で実際に起きた）ので、負荷に応じて待ちを延ばす
            let app = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
            let delay = enterDelay(chars: text.count)
            Events.log("enter_scheduled", ["delay_ms": Int(delay * 1000)])
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // 待っている間に別のアプリに移っていたら送らない（貼った先でないところで Enter を押さない）
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app else { return Events.log("enter_skipped", ["reason": "app_changed"]) }
                postKey(36, flags: [])
            }
        }
        // 元のクリップボードを戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard Settings.restoreClipboard, let previous else { return }
            if pb.string(forType: .string) == text {
                pb.clearContents()
                pb.setString(previous, forType: .string)
            }
        }
        return pastedAt
    }

    // paste_at の書式: UTC・ミリ秒（例 2026-10-17T02:39:12.345Z）。Claude Code のセッション記録の timestamp と同じ形
    static func utcMillis(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Paste visibility (iTerm)
//
// 貼ったあと、iTerm の今のセッションの画面（AppleScript の contents）を 150ms ごとに読み、貼った文の末尾が出るまでの時間を測る。
// Herdr の中のペインも iTerm の画面に描かれるので同じ方法で拾える。画面の中身は比べるのにだけ使い、どこにも書かない。
// オートメーション（Apple Events）の許可が要る。許可が無い・拒否されたときは測れなかった（visible_unknown）として、失敗には数えない

enum ITermScreen {
    static let bundleID = "com.googlecode.iterm2"
    // NSAppleScript はこの queue の上だけで使う（同時に動かさない）
    static let queue = DispatchQueue(label: "io.github.chaspy.koe.visible", qos: .utility)
    enum Read { case ok(session: String, contents: String), denied, failed }
    private static let script: NSAppleScript? = {
        let s = NSAppleScript(source: "tell application id \"\(bundleID)\" to tell current session of current window to return {id, contents}")
        var err: NSDictionary?
        return s?.compileAndReturnError(&err) == true ? s : nil
    }()

    // 許可を聞かずに確かめる（noErr / errAEEventNotPermitted / errAEEventWouldRequireUserConsent / procNotFound）
    static func permission() -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    }

    // まだ聞いていなければ、ここで macOS が許可のダイアログを出す（答えるまで戻らない）
    static func read() -> Read {
        guard let script else { return .failed }
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        if let err { return (err[NSAppleScript.errorNumber] as? Int) == Int(errAEEventNotPermitted) ? .denied : .failed }
        guard r.numberOfItems == 2, let id = r.atIndex(1)?.stringValue, let c = r.atIndex(2)?.stringValue else { return .failed }
        return .ok(session: id, contents: c)
    }
}

enum VisibleWatch {
    // readMax: 画面を 1 回読むのにかかった最長の時間（iTerm が応答しない時間帯があり、そのときは画面の描き直しも遅れていると見られる）
    enum Result { case visible(ms: Int, readMax: Int), notVisible(readMax: Int), unknown(String) }
    static let timeout = 10.0
    static let interval = 0.15
    private static var denied = false  // queue の上だけで触る

    // done は main で呼ぶ
    static func start(_ text: String, pastedAt: Date, done: @escaping (Result) -> Void) {
        let tail = PasteVisible.tail(text)
        let finish = { (r: Result) in DispatchQueue.main.async { done(r) } }
        guard !tail.isEmpty else { return finish(.unknown("empty")) }
        var session: String?
        var readMax = 0
        var asking = false  // まだ許可を聞いていない（初回の読み取りで macOS がダイアログを出す）
        func poll() {
            let started = Date()
            let read = ITermScreen.read()
            let took = Date().timeIntervalSince(started)
            switch read {
            case .denied:
                denied = true
                finish(.unknown("no_permission"))
            case .failed:
                finish(.unknown("error"))
            case .ok(let id, let contents):
                // 初回は許可のダイアログに答えるまで戻らないことがある。そのあいだに 10 秒過ぎたら測れなかったとする
                if asking, Date().timeIntervalSince(pastedAt) > timeout { return finish(.unknown("waited_permission")) }
                asking = false
                if let session, session != id { return finish(.unknown("session_changed")) }
                session = id
                readMax = max(readMax, Int(took * 1000))
                // 読み終えた時刻で測る（画面を読んだのはこの時刻より前なので、出るまでの時間を短く見積もることはない）
                let elapsed = Date().timeIntervalSince(pastedAt)
                if PasteVisible.visible(tail: tail, in: contents) { return finish(.visible(ms: Int(elapsed * 1000), readMax: readMax)) }
                if elapsed >= timeout { return finish(.notVisible(readMax: readMax)) }
                // iTerm の応答が遅いときは、読むのに掛かった分だけ間を空ける（貼った先の負荷を増やさない）
                ITermScreen.queue.asyncAfter(deadline: .now() + max(interval, took)) { poll() }
            }
        }
        ITermScreen.queue.asyncAfter(deadline: .now() + 0.1) {
            if denied { return finish(.unknown("no_permission")) }
            switch ITermScreen.permission() {
            case OSStatus(errAEEventNotPermitted): denied = true; finish(.unknown("no_permission"))
            case OSStatus(procNotFound): finish(.unknown("not_running"))
            case OSStatus(errAEEventWouldRequireUserConsent): asking = true; poll()
            default: poll()
            }
        }
    }
}

// MARK: - Icon
//
// メニューバーのアイコン: 吹き出しの「o」（ロゴの o と同じ形）。録音中は塗りつぶす

enum KoeIcon {
    static func make(filled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let w: CGFloat = 2.3
            let ring = NSRect(x: 1.8, y: 3.25, width: 14.4, height: 13.3)
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 3.6, y: 6.8))
            tail.line(to: NSPoint(x: 2.2, y: 0.7))
            tail.line(to: NSPoint(x: 8.1, y: 4.0))
            tail.close()
            tail.fill()
            if filled {
                NSBezierPath(ovalIn: ring).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            } else {
                let p = NSBezierPath(ovalIn: ring.insetBy(dx: w / 2, dy: w / 2))
                p.lineWidth = w
                p.stroke()
            }
            for (x, h) in [(6.5, 2.9), (9.0, 5.4), (11.5, 2.9)] as [(CGFloat, CGFloat)] {
                NSBezierPath(roundedRect: NSRect(x: x - 0.95, y: 9.9 - h / 2, width: 1.9, height: h), xRadius: 0.95, yRadius: 0.95).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
    static let outline = make(filled: false)
    static let filled = make(filled: true)
}

// MARK: - App

// MARK: - Events
//
// 押下ごとの結果を events.jsonl に 1 行ずつ残す。貼られなかった発話（取りこぼし）を後から数えられる。

enum Events {
    static let failures: Set<String> = ["not_ready", "start_failed", "no_voice", "mic_silent", "hallucination", "error", "cancelled", "not_visible"]

    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/events.jsonl")
    }

    static func log(_ outcome: String, _ extra: [String: Any] = [:]) {
        var e = extra
        e["t"] = ISO8601DateFormatter().string(from: Date())
        e["outcome"] = outcome
        guard var line = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line); try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    // ① 今日、押したのに入力されなかった割合の逆（Koe 内で分かる分。貼った先に届いたかは koe_eval.py trend）
    static func pasteSuccessToday() -> (ok: Int, total: Int) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (0, 0) }
        var ok = 0, ng = 0
        let f = ISO8601DateFormatter()
        for line in text.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let o = d["outcome"] as? String, let t = (d["t"] as? String).flatMap(f.date(from:)),
                  Calendar.current.isDateInToday(t) else { continue }
            if o == "pasted" { ok += 1 }
            else if o == "not_visible" { ok -= 1; ng += 1 }  // 貼ったが 10 秒たっても画面に出なかった（iTerm）
            else if ["no_voice", "mic_silent", "hallucination", "error", "not_ready", "start_failed", "missed_press", "no_accessibility", "no_microphone", "target_changed"].contains(o) { ng += 1 }
            else if o == "cancelled", d["reason"] as? String != "mouse", (d["hold_seconds"] as? Double ?? 0) >= 1.0 { ng += 1 }
        }
        return (ok, ok + ng)
    }

    // 今日 iTerm に貼った文が画面に出るまで（visible_ms）と、出なかった件数
    static func visibleToday() -> (ms: [Int], notVisible: Int) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return ([], 0) }
        var ms: [Int] = [], nv = 0
        let f = ISO8601DateFormatter()
        for line in text.split(separator: "\n") where line.contains("visible") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let o = d["outcome"] as? String, let t = (d["t"] as? String).flatMap(f.date(from:)),
                  Calendar.current.isDateInToday(t) else { continue }
            if o == "visible", let m = d["visible_ms"] as? Int { ms.append(m) } else if o == "not_visible" { nv += 1 }
        }
        return (ms.sorted(), nv)
    }

    static func failuresToday() -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").filter { line in
            guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let o = d["outcome"] as? String, let t = d["t"] as? String,
                  let date = ISO8601DateFormatter().date(from: t) else { return false }
            return failures.contains(o) && Calendar.current.isDateInToday(date)
        }.count
    }
}

// MARK: - Diagnostics

// 送ってもらう用の診断情報。版・機種・設定・動作の記録・速さ・whisper のログをまとめる。
// 文字起こしの本文・録音・辞書の中身は入れない（設定の秘密の値と、語や本文が入りうる欄は伏せる）
enum Diagnostics {
    static func sh(_ cmd: String) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // デスクトップに Koe-diagnostics-<日時>.zip を作り、その場所を返す
    static func export() throws -> URL {
        let fm = FileManager.default
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        let stamp = f.string(from: Date())
        let work = fm.temporaryDirectory.appendingPathComponent("Koe-diagnostics-\(stamp)")
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let koeDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe")
        let info = Bundle.main.infoDictionary
        var lines: [String] = []
        lines.append("Koe \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))")
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("機種 \(sh("sysctl -n hw.model")) / CPU \(sh("sysctl -n machdep.cpu.brand_string")) / 論理 CPU \(ProcessInfo.processInfo.processorCount) / メモリ \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { lines.append(String(format: "負荷 %.1f %.1f %.1f / 起動から %@", load[0], load[1], load[2], sh("uptime | sed 's/.*up \\([^,]*\\),.*/\\1/'"))) }
        lines.append("モデル \(Settings.model)（\(((try? fm.attributesOfItem(atPath: (Settings.model as NSString).expandingTildeInPath))?[.size] as? Int ?? 0) / 1_048_576) MB）")
        lines.append("入力デバイス: \(AudioDevices.inputs().map(\.name).joined(separator: " / "))")
        lines.append("")
        lines.append("## 設定（秘密の値・本文が入りうる値は伏せた）")
        let dom = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "io.github.chaspy.koe") ?? [:]
        for k in dom.keys.sorted() where !k.hasPrefix("NS") { lines.append("- \(k) = \(Redaction.redactSetting(k, dom[k]!))") }
        lines.append("")
        let keep = Settings.historyKeepDays
        let hu = Retention.usage(History.dir)
        lines.append("## 履歴（中身は入れない）")
        lines.append(keep > 0 ? "保存期間: 録音 \(keep) 日・文字 \(Retention.textDays(keep)) 日（1GB を超えたら古い録音から消す）" : "保存期間: ずっと（消さない）")
        lines.append(String(format: "大きさ: %.1f MB・%d ファイル・いちばん古い日 %@", Double(hu.bytes) / 1_048_576, hu.files, hu.oldest ?? "なし"))
        lines.append("")
        lines.append("## 辞書の大きさ（中身は入れない）")
        lines.append("個人の辞書 \(Glossary.personal.count) 語 / パック \(Glossary.packs.count) 語 / 組織の辞書 \(Glossary.org.count) 語 / 社員名簿 \(PeopleStore.all.count) 人")
        lines.append("")
        lines.append("## 直近 300 回の速さと結果（数字だけ）")
        lines.append("id\tapp\taudio_s\tvoiced_s\ttranscribe_ms\trelease_to_paste_ms\tload1\tpeak\tlevel_db\tpasted\tcommunication\timpact\tvisible\tvisible_ms")
        for r in History.recentRecords(300) {
            let q = r["quality"] as? [String: Any]
            let row: [Any?] = [r["id"], r["app"], r["audio_seconds"], r["voiced_seconds"], r["transcribe_ms"], r["release_to_paste_ms"],
                               r["load1"], r["peak"], q?["level_db"], (r["pasted"] is String), r["communication"], r["communication_impact"],
                               r["visible"], r["visible_ms"]]
            lines.append(row.map { $0.map { "\($0)" } ?? "" }.joined(separator: "\t"))
        }
        try lines.joined(separator: "\n").write(to: work.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        // 動作の記録（直近 3000 行。語・本文が入りうる欄は伏せる）
        if let ev = try? String(contentsOf: koeDir.appendingPathComponent("events.jsonl"), encoding: .utf8) {
            let tail = ev.split(separator: "\n").suffix(3000).compactMap { Redaction.redactEvent(String($0)) }
            try tail.joined(separator: "\n").write(to: work.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        }
        // whisper のログ（末尾 500 行。音声認識の結果の文は whisper-server のログには出さない設定）
        if let log = try? String(contentsOf: WhisperServer.logURL, encoding: .utf8) {
            try log.split(separator: "\n", omittingEmptySubsequences: false).suffix(500).joined(separator: "\n")
                .write(to: work.appendingPathComponent("whisper-server.log"), atomically: true, encoding: .utf8)
        }
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let zip = desktop.appendingPathComponent("Koe-diagnostics-\(stamp).zip")
        try? fm.removeItem(at: zip)
        _ = sh("cd \"\(work.deletingLastPathComponent().path)\" && /usr/bin/zip -qr \"\(zip.path)\" \"\(work.lastPathComponent)\"")
        try? fm.removeItem(at: work)
        guard fm.fileExists(atPath: zip.path) else { throw NSError(domain: "Koe", code: 30, userInfo: [NSLocalizedDescriptionKey: "zip を作れませんでした"]) }
        return zip
    }
}

// MARK: - Self update

// 公開版（GitHub の Release）に新しい版が出ていたら知らせ、押せば dmg を落として入れ替える。
// 署名の証明書が同じなら、マイク・アクセシビリティの許可は入れ替え後も残る
enum Updater {
    struct Release { let version: String; let dmg: URL; let page: URL }
    static var repo: String { Settings.defaults.string(forKey: "updateRepo") ?? "chaspy/koe" }
    static var current: String {
        Settings.defaults.string(forKey: "assumeVersion") ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    // GitHub の API（ログインなしは同じ IP から 1 時間 60 回まで。社内は皆同じ IP）は使わず、
    // 「最新の Release」のページの転送先（/releases/tag/vX.Y.Z）から版を読む
    final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    static func check(done: @escaping (Release?) -> Void) {
        guard Settings.defaults.object(forKey: "updateCheck") as? Bool ?? true,
              let url = URL(string: "https://github.com/\(repo)/releases/latest") else { return done(nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 20
        session.dataTask(with: req) { _, resp, _ in
            guard let loc = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
                  let r = loc.range(of: "/releases/tag/v") else { return done(nil) }
            let v = String(loc[r.upperBound...])
            guard newer(v, than: current),
                  let dmg = URL(string: "https://github.com/\(repo)/releases/download/v\(v)/Koe-\(v).dmg"),
                  let page = URL(string: "https://github.com/\(repo)/releases/tag/v\(v)") else { return done(nil) }
            done(Release(version: v, dmg: dmg, page: page))
        }.resume()
    }

    // その版の CHANGELOG（タグの CHANGELOG.md。API は使わない）から macOS の最初の項目を 1 行で取る
    static func summary(_ r: Release, done: @escaping ((line: String?, noChanges: Bool)) -> Void) {
        guard let url = URL(string: "https://raw.githubusercontent.com/\(repo)/v\(r.version)/CHANGELOG.md") else { return done((nil, false)) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard (resp as? HTTPURLResponse)?.statusCode == 200, let data, let md = String(data: data, encoding: .utf8) else { return done((nil, false)) }
            done(UpdatePrompt.summary(changelog: md, version: r.version, platform: "macOS"))
        }.resume()
    }

    // dmg を落として中の Koe.app を取り出し、Koe が終わってから今の場所に入れ替えて起動し直す
    static func install(_ r: Release, progress: @escaping (String) -> Void, failed: @escaping (String) -> Void) {
        progress("v\(r.version) をダウンロード中…")
        URLSession.shared.downloadTask(with: r.dmg) { tmp, _, error in
            guard let tmp else { return DispatchQueue.main.async { failed("ダウンロードに失敗: \(error?.localizedDescription ?? "")") } }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("koe-update-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let dmg = work.appendingPathComponent("Koe.dmg")
            try? FileManager.default.moveItem(at: tmp, to: dmg)
            let mount = work.appendingPathComponent("mnt")
            func run(_ args: [String]) -> Int32 {
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = args
                p.standardOutput = Pipe(); p.standardError = Pipe()
                do { try p.run() } catch { return -1 }
                p.waitUntilExit(); return p.terminationStatus
            }
            guard run(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount.path, dmg.path]) == 0 else {
                return DispatchQueue.main.async { failed("dmg を開けませんでした") }
            }
            let staged = work.appendingPathComponent("Koe.app")
            let ok = run(["ditto", mount.appendingPathComponent("Koe.app").path, staged.path]) == 0
            _ = run(["hdiutil", "detach", "-quiet", mount.path])
            guard ok else { return DispatchQueue.main.async { failed("新しい版を取り出せませんでした") } }
            let target = Bundle.main.bundleURL.path
            let pid = ProcessInfo.processInfo.processIdentifier
            let script = """
            while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
            rm -rf "\(target)" && ditto "\(staged.path)" "\(target)" && xattr -dr com.apple.quarantine "\(target)" 2>/dev/null
            open "\(target)"
            rm -rf "\(work.path)"
            """
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            do { try p.run() } catch { return DispatchQueue.main.async { failed("入れ替えを始められませんでした") } }
            Events.log("update_installing", ["from": current, "to": r.version])
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }.resume()
    }
}

// MARK: - App

// 1 回の押下〜貼り付けまで。文字起こし中に次の録音を始められるよう、発話ごとに持つ
final class Utterance {
    var record: [String: Any]
    let pressedAt = Date()
    var releasedAt: Date?
    var capture: Capture?
    // ロック録音（2 回続けて押して始め、もう 1 回押して終える）。貼らずにテキストファイルへ書き出す
    var locked = false
    // トグルの押し方で始めた録音（もう一度押すまで続き、終わったら普通に貼る）
    var toggled = false
    // 履歴に保存したときの id（貼ったあとに分かった値を後から書き足す）
    var historyID: String?
    // 押した瞬間の前面のアプリ・ウィンドウ（貼る瞬間に前面が変わっていたら戻す）
    var focus: FocusRestore.Snapshot?
    init(app: String) { record = ["app": app] }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let server = WhisperServer()
    private let recorder = Recorder()
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var missLine: NSMenuItem!
    private var metricsLine: NSMenuItem!
    private var enterItem: NSMenuItem!
    private var lineBreakItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var monitors: [Any] = []
    private var hotkeyDown = false
    private var lastShortTap = Date.distantPast
    private var keyUpLagMs = 0
    private var lowLevelWarnedAt = Date.distantPast
    private var lockStopping = false
    private var warmItem: NSMenuItem!
    private var soundItem: NSMenuItem!
    private var llmItem: NSMenuItem!
    private var historyItem: NSMenuItem!
    private var keepItems: [NSMenuItem] = []
    private var micMenu: NSMenu!
    private var hotkeyMenu: NSMenu!
    private var pressModeMenu: NSMenu!
    private var updateItem: NSMenuItem!
    private var lockItem: NSMenuItem!
    private var availableUpdate: Updater.Release?
    // 了承型の更新通知（UpdatePrompt）
    private var lastUsedAt: Date?                 // 最後に押した / 貼った時刻
    private var updateSnoozedUntil: Date?         // 「あとで」から 24 時間（この起動中だけ）
    private var updateSummary: (version: String, line: String?, noChanges: Bool)?
    private var updatePromptTimer: Timer?
    private var updateAlert: NSAlert?
    private var packMenu: NSMenu!
    private var recentMenu: NSMenu!
    private var clipboardItem: NSMenuItem!
    // 貼った先で消えても取り戻せるよう、直近の文字起こしを持っておく
    private var recent: [(time: Date, text: String)] = []
    private var recentByApp: [String: (time: Date, text: String)] = [:]
    private let improver = Improver()
    private let permissionGuide = PermissionGuide()
    private var permissionItem: NSMenuItem!
    private var improveItem: NSMenuItem!
    private var improveNowItem: NSMenuItem!
    private var warmUpTimer: Timer?

    private var serverReady = false { didSet { render() } }
    private var errorMessage: String? { didSet { render() } }
    private var current: Utterance? { didSet { render() } }   // 録音中の発話
    private var transcribing = 0 { didSet { render() } }
    private var cleaning = 0 { didSet { render() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.image  // no .icns in the bundle; alerts would show the generic icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        handleSigterm()
        buildMenu()
        render()
        Glossary.refreshUsage()
        LearnedNotice.shared.start(statusItem: statusItem, busy: { [weak self] in
            guard let self else { return false }
            return self.current != nil || self.transcribing > 0 || self.cleaning > 0
        }, lastUsed: { [weak self] in self?.lastUsedAt })
        watchServer()
        // 初めて起動したときは「ログイン時に起動」をオンにする（再起動のたびに手で開かなくてよいように）。
        // 一度決めた後は、メニューで本人が切り替えた状態を尊重する
        if !Settings.defaults.bool(forKey: "loginItemDefaulted") {
            Settings.defaults.set(true, forKey: "loginItemDefaulted")
            if SMAppService.mainApp.status != .enabled {
                do { try SMAppService.mainApp.register(); Events.log("login_item_enabled") }
                catch { Events.log("login_item_failed", ["error": error.localizedDescription]) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showWelcomeIfFirstLaunch() }
        // 起動時と 1 日 1 回、古い履歴を消す（裏で。録音・貼り付けを待たせない）
        pruneHistory("launch")
        Timer.scheduledTimer(withTimeInterval: Retention.every, repeats: true) { [weak self] _ in self?.pruneHistory("daily") }
        // 起動時と 1 日 1 回、公開版に新しい版が出ていないか見る
        checkUpdate()
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in self?.checkUpdate() }

        requestPermissions()
        installMonitors()
        recorder.onRestart = { reason in Events.log("mic_restarted", ["reason": reason]) }
        recorder.onSourceChange = { name in
            Events.log("mic_switched", ["device": name, "notice": self.recorder.notice?.rawValue ?? ""])
            self.render()
        }
        recorder.setWarm(Settings.warmMic)
        recent = History.recentPasted(10)
        updateLLMWarmUp()
        watchSecureInput()
        Glossary.refreshOrgIfNeeded()
        Glossary.exportForReceivers()
        Glossary.refreshPackSources()
        PeopleStore.refresh()
        improver.onFinish = { _ in self.render() }

        prepareModelThenStart()
    }

    private var downloader: ModelDownloader?
    private var downloadProgress: Double? { didSet { render() } }

    // 初回はモデル（約 1.6GB）をダウンロードしてから whisper-server を起動する
    private func prepareModelThenStart() {
        guard !FileManager.default.fileExists(atPath: Settings.model) else { return startServer() }
        let d = ModelDownloader(dest: Settings.model)
        downloader = d
        downloadProgress = 0
        d.start(progress: { self.downloadProgress = $0 }, done: { result in
            self.downloader = nil
            self.downloadProgress = nil
            switch result {
            case .success: self.startServer()
            case .failure(let e): self.showError(e.localizedDescription, sticky: true)
            }
        })
    }

    // 1 分ごとに whisper-server が生きているかを見て、録音中でなければ起こし直す
    private func watchServer() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self, self.serverReady, self.current == nil, self.transcribing == 0 else { return }
            self.server.isAlive { alive in
                guard !alive else { return }
                DispatchQueue.main.async {
                    Events.log("server_restart", ["reason": "health_check"])
                    self.serverReady = false
                    self.render()
                    self.startServer()
                }
            }
        }
    }

    private func startServer() {
        // VAD（任意、VAD.swift）のモデルが無ければ先に取る。失敗しても VAD なしで whisper は起こす
        VAD.prepare { prepared in
            if case .failure(let e) = prepared { DispatchQueue.main.async { self.showError(e.localizedDescription) } }
            self.server.start { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success: self.serverReady = true
                    case .failure(let e): self.showError(e.localizedDescription, sticky: true)
                    }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
        writeState("stopped")
    }

    // 録音中・文字起こし中に終了を求められたら、貼り終えてから終了する（最大 20 秒）
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isBusy else { return .terminateNow }
        terminating = true
        Events.log("quit_deferred")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { if self.terminating { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }

    private var isBusy: Bool { current != nil || transcribing > 0 || cleaning > 0 }

    // make install が待機中になるまで待てるよう、状態をファイルに書く
    private var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe/state")
    }
    private var lastState = ""
    private func writeState(_ s: String) {
        guard s != lastState else { return }
        lastState = s
        try? s.write(to: stateURL, atomically: true, encoding: .utf8)
    }

    private var sigterm: DispatchSourceSignal?
    private func handleSigterm() {
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        sigterm = src
    }

    // パスワード欄や iTerm の Secure Keyboard Entry が有効な間は、他のアプリのキー入力が見えない
    private var secureInput = false
    private func watchSecureInput() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let on = IsSecureEventInputEnabled()
            guard on != self.secureInput else { return }
            self.secureInput = on
            Events.log(on ? "secure_input" : "secure_input_off")
            self.render()
        }
    }

    // MARK: Permissions

    private func requestPermissions() {
        permissionGuide.log = { Events.log($0, $1) }
        permissionGuide.onGranted = { p in
            if p == .accessibility { self.installMonitors() } else { self.recorder.reopen() }
            self.render()
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            if !ok { DispatchQueue.main.async { self.permissionGuide.showIfNeeded(reason: "launch", only: .microphone) } }
        }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            // 許可済みに見えて外れている（署名が変わった）ときも同じ案内を 1 回出す
            Events.log("no_accessibility_at_launch")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if !AXIsProcessTrusted() { self.showAccessibilityNotice(reason: "launch") }
            }
            // 許可されるまで待ってからキー監視を張り直す
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
                if AXIsProcessTrusted() {
                    t.invalidate()
                    self.installMonitors()
                    self.render()
                }
            }
        }
    }

    // MARK: Hotkey (push to talk)

    private func installMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handle(e) }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { e in handler(e); return e }) {
            monitors.append(l)
        }
    }

    private func handle(_ e: NSEvent) {
        let key = Settings.hotkeyKeyCode
        switch e.type {
        case .keyDown:
            // ホットキーを押したまま他のキー = ショートカット操作。録音を取り消す
            if hotkeyDown { cancel(reason: "key \(e.keyCode)") }
        case .flagsChanged:
            if e.keyCode == key, let mask = deviceModifierMask[key] {
                let pressed = e.modifierFlags.rawValue & mask != 0
                if pressed && !hotkeyDown {
                    hotkeyDown = true
                    // ロック録音中にもう一度押したら、離したときに終える
                    if current?.locked == true || current?.toggled == true { lockStopping = true } else { begin() }
                }
                else if !pressed && hotkeyDown {
                    hotkeyDown = false
                    // 実際に離した時刻（イベントに付いている起動からの秒数）と、Koe が気づいた時刻の差。Mac が重いと知らせが遅れる
                    keyUpLagMs = Int((ProcessInfo.processInfo.systemUptime - e.timestamp) * 1000)
                    if lockStopping {
                        lockStopping = false
                        if current?.locked == true { endLocked() } else { end() }
                    } else { end() }
                }
                else if pressed && hotkeyDown {
                    // 離したイベントを取りこぼしていた。前の録音を確定してから録り直す
                    Events.log("missed_release")
                    end()
                    begin()
                } else {
                    // 押したイベントを取りこぼしていた（Koe には録音が残らない）
                    Events.log("missed_press")
                    fail("キーの押下を検知できませんでした。もう一度押してください")
                }
            } else if hotkeyDown {
                // 別の修飾キーが絡んだらショートカット操作とみなす
                cancel(reason: "modifier \(e.keyCode)")
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            // ⌘+クリック・⌘+スクロールはショートカット操作。黙って取り消す
            // ⌘+クリックは押してすぐのクリック。話している途中（1 秒以上）のクリックでは取り消さない（話した分が消えていた）
            if hotkeyDown, let u = current, Date().timeIntervalSince(u.pressedAt) < 1.0 { cancel(reason: "mouse", silent: true) }
        default: break
        }
    }

    private func begin() {
        guard current == nil else { return }
        // モデルの初回ダウンロード中だけは断る。起こし直しの最中なら録音し、離したときに準備ができるのを待って文字起こしする
        guard serverReady || downloadProgress == nil && FileManager.default.fileExists(atPath: Settings.model) else {
            Events.log("not_ready")
            fail("モデル読み込み中です。少し待ってから話してください")
            return
        }
        if PermissionGuide.enabled && PermissionCheck.micDenied {
            Events.log("no_microphone")
            fail("マイクの許可が必要です")
            permissionGuide.showIfNeeded(reason: "record", only: .microphone)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        let u = Utterance(app: front?.bundleIdentifier ?? "")
        lastUsedAt = Date()
        // 押した瞬間に whisper-server が生きているかを見る。止まっていたら、話している間に起こし直しておく
        server.isAlive { alive in
            guard !alive else { return }
            DispatchQueue.main.async {
                guard self.serverReady else { return }
                Events.log("server_restart", ["reason": "key_down_check"])
                self.serverReady = false
                self.render()
                self.startServer()
            }
        }
        if recorder.start() {
            // 開始音はマイクに入り込むので小さめに鳴らす
            play(Settings.startSound, volume: 0.35)
            current = u
            // 押したときのウィンドウは、録音を始めた後に裏で取る（貼る瞬間に前面が変わっていたら戻す）
            if let f = front { FocusRestore.capture(pid: f.processIdentifier, bundleID: f.bundleIdentifier ?? "") { u.focus = $0 } }
        } else {
            // 理由とデバイスの種類（transport）だけを記録する。デバイス名は書かない
            var extra: [String: Any] = [:]
            if let f = recorder.lastStartFailure { extra["reason"] = f.rawValue }
            if let t = recorder.primaryTransport { extra["transport"] = t }
            Events.log("start_failed", extra)
            fail(MicTap.message(recorder.lastStartFailure))
        }
    }

    // ロック録音を終える。押していた時間ではなく、録音の長さで扱う
    private func endLocked() {
        guard let u = current, u.locked else { return }
        Events.log("lock_stopped", ["seconds": round(Date().timeIntervalSince(u.pressedAt))])
        // end() の短押し判定にかからないよう、押した時刻からの長さで確定する
        end()
    }

    private func cancel(reason: String, silent: Bool = false) {
        guard let u = current, !u.locked, !u.toggled else { return }
        current = nil
        recorder.discard()
        let held = Date().timeIntervalSince(u.pressedAt)
        Events.log("cancelled", ["reason": reason, "hold_seconds": round(held * 100) / 100])
        // 1 秒以上押してから取り消された＝話している最中に他のキーに触れた可能性が高いので知らせる
        if held >= 1.0 && !silent { fail("他のキーに触れたので録音を取り消しました") }
    }

    private func end() {
        guard let u = current else { return }
        let held = Date().timeIntervalSince(u.pressedAt)
        if Settings.toggleMode && !u.toggled && held < 0.5 {
            // トグルの押し方: 短く押したら録音を続け、次に押したら終えて貼る
            u.toggled = true
            Events.log("toggle_started")
            render()
            return
        }
        if held < Settings.minHoldSeconds {
            // 短く 2 回続けて押した＝ロック録音。録音は続けたまま、次に押すまで待つ
            if u.pressedAt.timeIntervalSince(lastShortTap) < 0.5 {
                u.locked = true
                lastShortTap = .distantPast
                // いつもの開始音と区別できるよう、上がる 2 音を鳴らす
                play("lock_start", volume: 0.5)
                Events.log("lock_started")
                render()
                return
            }
            current = nil
            lastShortTap = Date()
            recorder.discard()
            Events.log("too_short", ["hold_seconds": round(held * 100) / 100])
            return
        }
        current = nil
        u.record["hold_seconds"] = round(held * 100) / 100
        // 速さの計測: 離した時刻と、そのときの Mac の負荷・裏で改善ループが動いていたか
        u.releasedAt = Date()
        u.record["key_up_lag_ms"] = keyUpLagMs
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { u.record["load1"] = round(load[0] * 10) / 10 }
        u.record["improve_running"] = improver.running
        transcribing += 1
        recorder.stop { cap in
            if let r = u.releasedAt { u.record["stop_ms"] = Int(Date().timeIntervalSince(r) * 1000) }
            // 終了音は録り足し（語尾の切れ対策）が終わってから鳴らす。録音に入れないため
            self.play(u.locked ? "lock_stop" : Settings.stopSound)
            u.capture = cap
            u.record["audio_seconds"] = round(cap.seconds * 100) / 100
            u.record["voiced_seconds"] = round(cap.voicedSeconds * 100) / 100
            u.record["peak"] = cap.peak
            u.record["device"] = cap.device
            if !cap.quality.isEmpty { u.record["quality"] = cap.quality }
            // 声が小さく録れている（入力音量が低い）と、語が途切れたり聞き取られなかったりする。10 分に 1 回まで知らせる
            if let l = cap.quality["level_db"] as? Double, l < -45, cap.voicedSeconds > 0,
               Date().timeIntervalSince(self.lowLevelWarnedAt) > 600 {
                self.lowLevelWarnedAt = Date()
                Events.log("low_level", ["level_db": l])
                self.showError(String(format: "声が小さく録れています（%.0f dB）。システム設定 → サウンド → 入力 で入力音量を上げるか、マイクを口元に近づけてください", l))
            }
            if let alt = cap.alt { u.record["alt_device"] = alt.device; u.record["alt_quality"] = alt.quality }
            // 部屋の雑音でも peak は数十〜数百ある。ほぼ 0 はミュートか入力停止
            if cap.seconds >= 0.5 && cap.peak <= 2 {
                self.transcribing -= 1
                self.drop(u, outcome: "mic_silent", message: MicNotice.silentMessage(self.recorder.notice) ?? "マイクから音が来ていません。マイクがミュートになっていませんか？")
            } else if cap.voicedSeconds == 0 {
                self.transcribing -= 1
                // 1 秒未満で声もない押下は誤操作のことが多いので音は鳴らさない
                self.drop(u, outcome: "no_voice", message: "声を検出できませんでした", silent: held < 1.0)
            } else {
                let p0 = Date()
                let prompt = Settings.whisperPrompt(previous: u.locked ? nil : self.previousText(for: u))
                u.record["prompt_ms"] = Int(Date().timeIntervalSince(p0) * 1000)
                self.transcribe(u, prompt: prompt)
            }
        }
    }

    private func play(_ name: String, volume: Float = 1.0) {
        guard Settings.sounds else { return }
        let sound = Bundle.main.url(forResource: name, withExtension: "aiff").flatMap { NSSound(contentsOf: $0, byReference: true) }
            ?? NSSound(named: NSSound.Name(name))
        sound?.volume = volume
        sound?.play()
    }

    // アクセシビリティの許可が無いと、送った ⌘V は黙って捨てられる（貼れたように見えて何も入らない）。
    // ビルドの署名が変わると、システム設定では許可済みに見えても実際は外れていることがある。
    // そのときは貼ったことにしない: 文はクリップボードに残し、outcome=no_accessibility で記録して知らせる
    private func blockedWithoutAccessibility(_ u: Utterance, _ text: String) -> Bool {
        guard !AXIsProcessTrusted() else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        u.record["outcome"] = "no_accessibility"
        u.record["kept_on_clipboard"] = true
        Events.log("no_accessibility", ["chars": text.count])
        fail("アクセシビリティの許可が外れています。文はクリップボードにあります（⌘V で貼れます）")
        finish(u, pasted: nil)
        showAccessibilityNotice(reason: "paste_blocked")
        return true
    }

    // 直し方をシステム設定の横に浮かべる（PermissionGuide。フォーカスは奪わない）
    private func showAccessibilityNotice(reason: String) {
        permissionGuide.showIfNeeded(reason: reason, only: .accessibility)
    }

    @objc private func openPermissionGuide() { permissionGuide.showIfNeeded(reason: "menu", manual: true) }

    // 貼る瞬間の前面のアプリを記録し（paste_app）、録音を始めたときのアプリ（app）と違えば貼らない。
    // 文字起こしを待つ間に別のアプリへ移ると、話した文が思わぬところに入る（入った先も分からない）ため。
    // 文はクリップボードと「最近の文字起こし」に残し、outcome=target_changed で記録して知らせる
    // ただし押してから 20 秒以内なら、押したときのアプリ・ウィンドウを前に戻して貼る（restored_focus）。戻せなかったときだけ target_changed
    private func blockedTargetChanged(_ u: Utterance, _ text: String) -> Bool {
        let now = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        u.record["paste_app"] = now
        let start = u.record["app"] as? String ?? ""
        let decision = PasteTarget.decide(start: start, now: now, sincePress: Date().timeIntervalSince(u.pressedAt), restoreEnabled: Settings.restoreFocus)
        if decision == .paste { return false }
        if decision == .restore, let snap = u.focus {
            switch FocusRestore.restore(snap) {
            case .restored(let ms):
                u.record["paste_app"] = start
                u.record["restored_focus"] = true
                u.record["restore_ms"] = ms
                u.record["restored_from"] = now
                Events.log("focus_restored", ["app": start, "from_app": now, "restore_ms": ms])
                return false
            case .failed(let reason):
                u.record["restore_failed"] = reason
            }
        } else if decision == .restore {
            u.record["restore_failed"] = "no_snapshot"  // 押したときのウィンドウをまだ取り終えていない
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        u.record["outcome"] = "target_changed"
        u.record["kept_on_clipboard"] = true
        Events.log("target_changed", ["app": start, "paste_app": now, "chars": text.count, "restore_failed": u.record["restore_failed"] ?? (decision == .restore ? "no_snapshot" : "off_or_late")])
        recent.append((Date(), text))
        if recent.count > 10 { recent.removeFirst(recent.count - 10) }
        fail("貼り先が変わったので貼りませんでした（⌘V で貼れます）")
        finish(u, pasted: nil)
        return true
    }

    // 取りこぼしは黙って捨てない。音とメニューで知らせる
    private func fail(_ message: String) {
        play(Settings.failSound)
        showError(message)
    }

    private func showError(_ message: String, sticky: Bool = false) {
        errorMessage = message
        guard !sticky else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if self.errorMessage == message { self.errorMessage = nil }
        }
    }

    // 話していた時間から失った文字数を見積もる（履歴の中央値で約 7 文字/秒）
    private func lossEstimate(_ u: Utterance) -> [String: Any] {
        let held = u.record["hold_seconds"] as? Double ?? Date().timeIntervalSince(u.pressedAt)
        return ["hold_seconds": round(held * 100) / 100, "est_lost_chars": Int(max(0, held - 0.3) * 7)]
    }

    private func drop(_ u: Utterance, outcome: String, message: String, silent: Bool = false) {
        u.record["dropped"] = true
        u.record["outcome"] = outcome
        var extra = lossEstimate(u)
        extra["voiced_seconds"] = u.record["voiced_seconds"] ?? 0
        extra["peak"] = u.record["peak"] ?? 0
        Events.log(outcome, extra)
        finish(u, pasted: nil)
        if silent { showError(message) } else { fail(message) }
    }

    // loopRetry: 繰り返しのやり直し（30 秒の枠全体・温度のフォールバックあり）
    // fullWindow: 縮めた窓で崩れた出力が出たあとのやり直し（30 秒の枠全体。#165）
    private func transcribe(_ u: Utterance, prompt: String, retried: Bool = false, loopRetry: Bool = false, fullWindow: Bool = false) {
        guard let cap = u.capture else { return }
        let started = Date()
        u.record["whisper_model"] = (Settings.model as NSString).lastPathComponent
        u.record["whisper_prompt"] = prompt
        // 窓は送る音声（無音を削った後）の長さに合わせる。繰り返しのやり直しは 30 秒の枠全体
        let actx = loopRetry || fullWindow ? 0 : AudioWindow.ctx(setting: Settings.audioCtx, seconds: cap.voicedSeconds > 0 ? cap.voicedSeconds : cap.seconds)
        u.record[loopRetry || fullWindow ? "whisper_audio_ctx_retry" : "whisper_audio_ctx"] = actx
        server.transcribe(wav: cap.url, prompt: prompt, keepLines: u.locked || Settings.keepLines, seconds: cap.seconds,
                          audioCtx: actx, temperatureInc: loopRetry ? "0.2" : nil) { result in
            DispatchQueue.main.async {
                u.record["transcribe_ms"] = Int(Date().timeIntervalSince(started) * 1000) + (u.record["transcribe_ms"] as? Int ?? 0)
                switch result {
                case .success(let text):
                    var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 縮めた窓で崩れた（日本語にない文字・読めないバイト）。30 秒の枠全体で 1 回だけやり直す
                    if actx != 0, let reason = AudioWindow.garbledReason(raw) {
                        Events.log("garbled_retry", ["reason": reason, "audio_ctx": actx, "chars": raw.count])
                        u.record["retried_full_window"] = reason
                        self.transcribe(u, prompt: prompt, retried: retried, fullWindow: true)
                        return
                    }
                    raw = AudioWindow.dropInvalid(raw)
                    let (t, applied) = Glossary.autocorrectWithLog(raw)
                    u.record["raw"] = t
                    u.record["packs"] = Settings.enabledPacks
                    if t != raw { u.record["raw_before_autocorrect"] = raw; u.record["autocorrected"] = applied }
                    if t.isEmpty || hallucinations.contains(t) {
                        // 声は入っているのに決まり文句が出た＝プロンプトに引っ張られた幻聴。プロンプトなしでやり直す
                        if !retried && cap.voicedSeconds >= 1.0 {
                            u.record["retried_without_prompt"] = true
                            self.transcribe(u, prompt: "", retried: true, fullWindow: fullWindow)
                            return
                        }
                        self.transcribing -= 1
                        self.drop(u, outcome: "hallucination", message: "うまく聞き取れませんでした。もう一度話してください")
                        return
                    }
                    if u.locked {
                        // ロック録音は貼らずにテキストに書き出す（長い話では同じ相槌が何度も出るので、繰り返しの扱いはしない）
                        self.transcribing -= 1
                        self.saveLocked(u, t)
                        return
                    }
                    let loop = isRepetitive(t), stock = hasStockPhrase(t)
                    if loop || stock {
                        // 同じ文・語の繰り返し（「ドラフ、ドラフ、…」）や、文の中の決まり文句（「…収募 (音楽)」）は読み間違い。
                        // 30 秒の枠全体・温度のフォールバックあり・プロンプトなしで 1 回だけやり直し、
                        // それでも残るなら繰り返しは 1 回に縮め、決まり文句は取り除いて貼る
                        if !retried {
                            if loop {
                                Events.log("repetition_retry", ["chars": t.count])
                                u.record["retried_for_repetition"] = true
                                u.record["repetition_before_retry"] = t
                            }
                            if stock {
                                Events.log("stock_phrase_retry", ["chars": t.count])
                                u.record["retried_for_stock_phrase"] = true
                                u.record["stock_phrase_before_retry"] = t
                            }
                            if !prompt.isEmpty { u.record["retried_without_prompt"] = true }
                            self.transcribe(u, prompt: "", retried: true, loopRetry: true)
                            return
                        }
                        var c = t
                        if loop {
                            u.record["repetition_collapsed"] = t
                            c = collapseRepeats(c)
                        }
                        if stock {
                            u.record["stock_phrase_removed"] = c
                            c = removeStockPhrases(c)
                        }
                        self.transcribing -= 1
                        if c.isEmpty {
                            self.drop(u, outcome: "hallucination", message: "うまく聞き取れませんでした。もう一度話してください")
                        } else {
                            self.deliver(u, c)
                        }
                        return
                    }
                    self.transcribing -= 1
                    self.deliver(u, t)
                case .failure(let e):
                    // whisper-server が止まっていた（強制終了など）。起こし直して 1 回だけやり直す（話した分を捨てない）
                    if !retried, let ue = e as? URLError, [.cannotConnectToHost, .networkConnectionLost, .cannotFindHost].contains(ue.code) {
                        u.record["server_restarted"] = true
                        Events.log("server_restart", ["reason": "transcribe_connect_failed"])
                        self.serverReady = false
                        self.render()
                        self.server.start { result in
                            DispatchQueue.main.async {
                                if case .success = result {
                                    self.serverReady = true
                                    self.render()
                                    self.transcribe(u, prompt: prompt, retried: true, fullWindow: fullWindow)
                                } else {
                                    self.transcribing -= 1
                                    u.record["error"] = e.localizedDescription
                                    Events.log("error", self.lossEstimate(u).merging(["error": "server restart failed"]) { a, _ in a })
                                    self.finish(u, pasted: nil)
                                    self.fail("文字起こしの仕組み（whisper）を起こし直せませんでした。Koe を終了して開き直してください")
                                }
                            }
                        }
                        return
                    }
                    self.transcribing -= 1
                    u.record["error"] = e.localizedDescription
                    var extra = self.lossEstimate(u)
                    extra["error"] = e.localizedDescription
                    Events.log("error", extra)
                    self.finish(u, pasted: nil)
                    self.fail("文字起こしに失敗: \(e.localizedDescription)")
                }
            }
        }
    }

    // ロック録音の結果を ~/Documents/Koe/<日時>.txt に書き出し、クリップボードにも入れて開く
    private func saveLocked(_ u: Utterance, _ text: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Koe")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        let url = dir.appendingPathComponent("\(f.string(from: u.pressedAt)).txt")
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        u.record["locked"] = true
        u.record["saved_to"] = url.path
        Events.log("lock_saved", ["seconds": u.record["audio_seconds"] ?? 0, "chars": text.count])
        finish(u, pasted: nil)
        NSWorkspace.shared.open(url)
    }

    // 離してから貼り付けまで（録り足し・文字起こし・整形を含む）
    private var recentLatency: [Int] = []
    // 前に戻してから貼ったときの記録（数字と種類だけ）
    private func restoreFields(_ u: Utterance) -> [String: Any] {
        guard u.record["restored_focus"] != nil else { return [:] }
        return ["restored_focus": true, "restore_ms": u.record["restore_ms"] ?? 0]
    }
    private func restoredPID(_ u: Utterance) -> pid_t? { u.record["restored_focus"] != nil ? u.focus?.pid : nil }

    private func markPasted(_ u: Utterance) {
        guard let r = u.releasedAt else { return }
        let ms = Int(Date().timeIntervalSince(r) * 1000)
        u.record["release_to_paste_ms"] = ms
        recentLatency.append(ms)
        if recentLatency.count > 20 { recentLatency.removeFirst() }
    }

    private func deliver(_ u: Utterance, _ raw: String) {
        u.record["llm_enabled"] = Settings.llmEnabled
        guard Settings.llmEnabled else {
            if blockedWithoutAccessibility(u, raw) { return }
            if blockedTargetChanged(u, raw) { return }
            markPasted(u)
            let at = Typist.pasteAndMaybeEnter(raw, enter: Settings.shouldEnter(bundle: u.record["paste_app"] as? String), targetPID: restoredPID(u))
            u.record["paste_at"] = Typist.utcMillis(at)
            watchVisible(u, raw, at)
            Events.log("pasted", ["retried": u.record["retried_without_prompt"] != nil, "app": u.record["app"] ?? "", "paste_app": u.record["paste_app"] ?? "", "paste_at": u.record["paste_at"] ?? ""].merging(restoreFields(u)) { a, _ in a })
            finish(u, pasted: raw)
            return
        }
        cleaning += 1
        u.record["llm_model"] = Settings.llmModel
        u.record["llm_prompt"] = Cleaner.prompt()
        let started = Date()
        Cleaner.clean(raw) { result in
            DispatchQueue.main.async {
                self.cleaning -= 1
                u.record["clean_ms"] = Int(Date().timeIntervalSince(started) * 1000)
                var text = raw
                switch result {
                case .success(let cleaned) where !cleaned.isEmpty:
                    u.record["cleaned"] = cleaned
                    text = cleaned
                case .success:
                    u.record["llm_error"] = "empty response"
                case .failure(let e):
                    // 整形に失敗しても入力は失わない
                    u.record["llm_error"] = e.localizedDescription
                }
                if self.blockedWithoutAccessibility(u, text) { return }
                if self.blockedTargetChanged(u, text) { return }
                self.markPasted(u)
                let at = Typist.pasteAndMaybeEnter(text, enter: Settings.shouldEnter(bundle: u.record["paste_app"] as? String), targetPID: self.restoredPID(u))
                u.record["paste_at"] = Typist.utcMillis(at)
                self.watchVisible(u, text, at)
                Events.log("pasted", ["llm": true, "app": u.record["app"] ?? "", "paste_app": u.record["paste_app"] ?? "", "paste_at": u.record["paste_at"] ?? ""].merging(self.restoreFields(u)) { a, _ in a })
                self.finish(u, pasted: text)
            }
        }
    }

    // iTerm に貼ったときだけ、画面に出るまでを測って events と履歴に書く（数字と outcome だけ）。
    // 結果が出るのは finish で履歴に保存した後なので、履歴には後から書き足す
    private func watchVisible(_ u: Utterance, _ text: String, _ at: Date) {
        guard Settings.measureVisible, (u.record["paste_app"] as? String)?.lowercased() == ITermScreen.bundleID else { return }
        VisibleWatch.start(text, pastedAt: at) { r in
            var outcome = "visible_unknown", extra: [String: Any] = [:]
            switch r {
            case .visible(let ms, let readMax): outcome = "visible"; extra["visible_ms"] = ms; extra["read_ms_max"] = readMax
            case .notVisible(let readMax): outcome = "not_visible"; extra["waited_ms"] = Int(VisibleWatch.timeout * 1000); extra["read_ms_max"] = readMax
            case .unknown(let why): extra["reason"] = why
            }
            Events.log(outcome, extra.merging(["app": ITermScreen.bundleID, "paste_at": u.record["paste_at"] ?? ""]) { a, _ in a })
            var fields: [String: Any] = ["visible": outcome]
            if let ms = extra["visible_ms"] { fields["visible_ms"] = ms }
            if let why = extra["reason"] { fields["visible_reason"] = why }
            if let m = extra["read_ms_max"] { fields["visible_read_ms_max"] = m }
            u.record.merge(fields) { _, b in b }
            if let id = u.historyID { History.merge(id: id, fields) }
        }
    }

    // 同じアプリに 3 分以内に貼った直前の発話
    private func previousText(for u: Utterance) -> String? {
        guard let last = recentByApp[u.record["app"] as? String ?? ""],
              u.pressedAt.timeIntervalSince(last.time) < 180 else { return nil }
        return last.text
    }

    private func finish(_ u: Utterance, pasted: String?) {
        lastUsedAt = Date()
        if let text = pasted {
            Glossary.refreshUsage(ifOlderThan: 300)
            recentByApp[u.record["app"] as? String ?? ""] = (Date(), text)
            recent.append((Date(), text))
            if recent.count > 10 { recent.removeFirst(recent.count - 10) }
        }
        guard let cap = u.capture else { return }
        defer { if current == nil && transcribing == 0 { improver.runIfNeeded() } }
        if Settings.saveHistory {
            u.record["pasted"] = pasted ?? NSNull()
            let id = History.newID()
            u.historyID = id
            History.save(id: id, wav: cap.url, record: u.record, alt: cap.alt?.url)
        } else {
            try? FileManager.default.removeItem(at: cap.url)
            if let a = cap.alt?.url { try? FileManager.default.removeItem(at: a) }
        }
        render()
    }

    // Ollama は既定 5 分でモデルを降ろすので、有効な間は定期的に空打ちして載せておく
    private func updateLLMWarmUp() {
        warmUpTimer?.invalidate()
        warmUpTimer = nil
        guard Settings.llmEnabled else { return }
        Cleaner.warmUp()
        warmUpTimer = Timer.scheduledTimer(withTimeInterval: 240, repeats: true) { _ in Cleaner.warmUp() }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        missLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        missLine.isEnabled = false
        menu.addItem(missLine)
        metricsLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        metricsLine.isEnabled = false
        menu.addItem(metricsLine)
        permissionItem = NSMenuItem(title: "許可の案内を開く…", action: #selector(openPermissionGuide), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())

        // ロック録音はキーの 2 回押しでも始められるが、気づきにくいのでメニューからも始め・止められるようにする
        lockItem = NSMenuItem(title: "", action: #selector(toggleLock), keyEquivalent: "")
        lockItem.target = self
        menu.addItem(lockItem)
        menu.addItem(.separator())

        enterItem = NSMenuItem(title: "貼り付け後に Enter を送る（ターミナルのみ）", action: #selector(toggleEnter), keyEquivalent: "")
        enterItem.target = self
        menu.addItem(enterItem)

        lineBreakItem = NSMenuItem(title: "区切りごとに改行する（ターミナル以外。Docs 向け）", action: #selector(toggleLineBreaks), keyEquivalent: "")
        lineBreakItem.target = self
        menu.addItem(lineBreakItem)

        warmItem = NSMenuItem(title: "マイクを常時待機（頭切れ防止）", action: #selector(toggleWarm), keyEquivalent: "")
        warmItem.target = self
        menu.addItem(warmItem)

        llmItem = NSMenuItem(title: "", action: #selector(toggleLLM), keyEquivalent: "")
        llmItem.target = self
        menu.addItem(llmItem)

        improveItem = NSMenuItem(title: "使うほど賢くする（改善ループ）", action: #selector(toggleImprove), keyEquivalent: "")
        improveItem.target = self
        menu.addItem(improveItem)
        improveNowItem = NSMenuItem(title: "今すぐ改善する", action: #selector(improveNow), keyEquivalent: "")
        improveNowItem.target = self
        menu.addItem(improveNowItem)

        let recentItem = NSMenuItem(title: "最近の文字起こし（クリックでコピー）", action: nil, keyEquivalent: "")
        recentMenu = NSMenu()
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        clipboardItem = NSMenuItem(title: "貼り付け後にクリップボードを元に戻す", action: #selector(toggleClipboard), keyEquivalent: "")
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        let packItem = NSMenuItem(title: "用語パック", action: nil, keyEquivalent: "")
        packMenu = NSMenu()
        packMenu.delegate = self
        packItem.submenu = packMenu
        menu.addItem(packItem)
        menu.addItem(GlossaryWindow.menuItem())

        // 押して話すキー。US 配列では右⌘が ⌘+Space（入力切替）や ⌘+Return と競合するので選べるようにする
        let keyItem = NSMenuItem(title: "押して話すキー", action: nil, keyEquivalent: "")
        hotkeyMenu = NSMenu()
        for (code, name) in [(54, "右⌘"), (61, "右⌥"), (62, "右⌃"), (63, "fn（地球儀）")] as [(Int, String)] {
            let it = NSMenuItem(title: name, action: #selector(chooseHotkey(_:)), keyEquivalent: "")
            it.target = self
            it.tag = code
            hotkeyMenu.addItem(it)
        }
        keyItem.submenu = hotkeyMenu
        menu.addItem(keyItem)

        let modeItem = NSMenuItem(title: "押し方", action: nil, keyEquivalent: "")
        pressModeMenu = NSMenu()
        for (tag, name) in [(0, "押している間だけ録音（既定）"), (1, "押すたびに開始・終了（トグル）")] as [(Int, String)] {
            let it = NSMenuItem(title: name, action: #selector(choosePressMode(_:)), keyEquivalent: "")
            it.target = self
            it.tag = tag
            pressModeMenu.addItem(it)
        }
        modeItem.submenu = pressModeMenu
        menu.addItem(modeItem)

        let micItem = NSMenuItem(title: "マイク", action: nil, keyEquivalent: "")
        micMenu = NSMenu()
        micMenu.delegate = self
        micItem.submenu = micMenu
        menu.addItem(micItem)

        historyItem = NSMenuItem(title: "録音と結果を保存（評価用）", action: #selector(toggleHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        let keepItem = NSMenuItem(title: "履歴を残す期間", action: nil, keyEquivalent: "")
        let keepMenu = NSMenu()
        for d in Retention.choices {
            let mi = NSMenuItem(title: Retention.label(d), action: #selector(setHistoryKeep(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = d
            keepMenu.addItem(mi)
            keepItems.append(mi)
        }
        keepMenu.addItem(.separator())
        let keepNote = NSMenuItem(title: "文字は録音の約 2 倍残す。全体で 1GB を超えたら古い録音から消す", action: nil, keyEquivalent: "")
        keepNote.isEnabled = false
        keepMenu.addItem(keepNote)
        keepItem.submenu = keepMenu
        menu.addItem(keepItem)

        soundItem = NSMenuItem(title: "録音の開始・終了で音を鳴らす", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        menu.addItem(soundItem)

        loginItem = NSMenuItem(title: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let importItem = NSMenuItem(title: "設定ファイルを読み込む…", action: #selector(importConfig), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let hist = NSMenuItem(title: "保存フォルダを開く", action: #selector(openHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)

        let help = NSMenuItem(title: "使い方", action: #selector(openHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        let diag = NSMenuItem(title: "診断情報を書き出す（不具合を送る用）", action: #selector(exportDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        let log = NSMenuItem(title: "サーバーログを開く", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())
        let info = Bundle.main.infoDictionary
        let ver = NSMenuItem(title: "Koe \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))", action: nil, keyEquivalent: "")
        ver.isEnabled = false
        menu.addItem(ver)
        updateItem = NSMenuItem(title: "", action: #selector(installUpdate), keyEquivalent: "")
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        let checkItem = NSMenuItem(title: "更新を確認", action: #selector(checkUpdateNow), keyEquivalent: "")
        checkItem.target = self
        menu.addItem(checkItem)
        let quit = NSMenuItem(title: "終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func toggleLock() {
        if let c = current, c.locked {
            endLocked()
        } else if current == nil {
            begin()
            guard let u = current else { return }
            u.locked = true
            play("lock_start", volume: 0.5)
            Events.log("lock_started", ["from": "menu"])
        }
        render()
    }

    @objc private func toggleLineBreaks() {
        Settings.lineBreaks.toggle()
        render()
    }

    @objc private func toggleEnter() {
        Settings.autoEnter.toggle()
        render()
    }

    @objc private func toggleWarm() {
        Settings.warmMic.toggle()
        recorder.setWarm(Settings.warmMic)
        render()
    }

    @objc private func toggleLLM() {
        Settings.llmEnabled.toggle()
        updateLLMWarmUp()
        render()
    }

    // サブメニューを開くたびにマイク一覧を作り直す（抜き差しに追従）
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusItem.menu {
            // メニューを開いたときも、前に確かめてから 1 分以上たっていれば新しい版を確かめる（起動時と 1 日 1 回だけだと当日中に気づけない）
            if Date().timeIntervalSince(lastUpdateCheck) > 60 { checkUpdate() }
            GlossaryWindow.updateMenuItem(in: menu)
            // 計測はメニューを開いたときだけ数える（履歴を読むので重い）
            let p1 = Events.pasteSuccessToday(), p2 = History.communication()
            func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.0f%%", Double(a) / Double(b) * 100) }
            func pct1(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.1f%%", Double(a) / Double(b) * 100) }
            var speed = ""
            if !recentLatency.isEmpty {
                let m = recentLatency.sorted()[recentLatency.count / 2]
                speed = String(format: " / 離して→貼る %.1f 秒（直近 %d 回の中央）", Double(m) / 1000, recentLatency.count)
            }
            let v: (ms: [Int], notVisible: Int) = Settings.measureVisible ? Events.visibleToday() : ([], 0)
            if !v.ms.isEmpty || v.notVisible > 0 {
                let med = v.ms.isEmpty ? "-" : String(format: "%.1f", Double(v.ms[v.ms.count / 2]) / 1000)
                let p90 = v.ms.isEmpty ? "-" : String(format: "%.1f", Double(v.ms[min(v.ms.count - 1, v.ms.count * 9 / 10)]) / 1000)
                speed += " / 貼る→画面に出る \(med) 秒（p90 \(p90) 秒）・出ず \(v.notVisible) 件（今日の iTerm）"
            }
            metricsLine?.title = "今日の入力成功 \(pct(p1.ok, p1.total))（\(p1.ok)/\(p1.total)） / 直近 \(p2.judged) 件: 誤解したまま作業 \(pct1(p2.misacted, p2.judged))・言い直し \(pct1(p2.redo, p2.judged))" + speed
            return
        }
        if menu === recentMenu {
            menu.removeAllItems()
            if recent.isEmpty {
                let none = NSMenuItem(title: "まだありません", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            for r in recent.reversed() {
                let short = r.text.count > 40 ? String(r.text.prefix(40)) + "…" : r.text
                let item = NSMenuItem(title: "\(f.string(from: r.time))  \(short)", action: #selector(copyRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = r.text
                item.toolTip = r.text
                menu.addItem(item)
            }
            return
        }
        if menu === packMenu {
            menu.removeAllItems()
            for p in Glossary.availablePacks {
                let item = NSMenuItem(title: p.title, action: #selector(togglePack(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = p.id
                item.state = Settings.enabledPacks.contains(p.id) ? .on : .off
                menu.addItem(item)
            }
            return
        }
        guard menu === micMenu else { return }
        menu.removeAllItems()
        let fb = recorder.fallbackName.map { "。ミュート中は \($0)" } ?? ""
        let auto = NSMenuItem(title: "自動（既定のマイク\(fb)）", action: #selector(selectMic(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = Settings.micName == nil ? .on : .off
        menu.addItem(auto)
        if let hint = MicNotice.menuHint(recorder.notice) { menu.addItem(withTitle: hint, action: nil, keyEquivalent: "").isEnabled = false }
        menu.addItem(.separator())
        let lid = Settings.micNotice && MicNotice.lidClosed()
        for d in AudioDevices.selectable() {
            let item = NSMenuItem(title: d.name + (Settings.micNotice ? MicNotice.itemSuffix(transport: d.transport, lidClosed: lid) : ""), action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.name
            item.state = Settings.micName == d.name ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func importConfig() {
        ConfigImport.run()
        recorder.reopen()
        render()
    }

    @objc private func toggleImprove() {
        if !Settings.improveEnabled {
            if Settings.improveProvider == "api" && Settings.improveEndpoint.isEmpty {
                showError("改善ループの送り先（improveEndpoint）が設定されていません")
                return
            }
            let a = NSAlert()
            a.messageText = "改善ループをオンにしますか？"
            let people = PeopleStore.all.count
            a.informativeText = "発話の文字起こしと、Claude Code のセッション記録の該当部分（送った文・返答・次の発話）を、次の送り先に送って辞書を育てます。"
                + (people > 0 ? "社員名簿（peopleSources、\(people) 人の ID と本名）も毎回送ります。" : "")
                + "\n\n送り先: \(Settings.improveTarget)"
            a.addButton(withTitle: "オンにする")
            a.addButton(withTitle: "やめる")
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        Settings.improveEnabled.toggle()
        render()
    }

    @objc private func improveNow() {
        improver.runIfNeeded(force: true)
        render()
    }

    @objc private func toggleClipboard() {
        Settings.restoreClipboard.toggle()
        render()
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Events.log("recent_copied", ["chars": text.count])
    }

    @objc private func togglePack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var on = Settings.enabledPacks
        if let i = on.firstIndex(of: id) { on.remove(at: i) } else { on.append(id) }
        Settings.enabledPacks = on
        Glossary.exportForReceivers()
        Events.log("pack_toggled", ["pack": id, "on": on.contains(id)])
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        Settings.micName = sender.representedObject as? String
        Events.log("mic_selected", ["device": Settings.micName ?? "auto"])
        recorder.reopen()
        render()
    }

    @objc private func toggleHistory() {
        Settings.saveHistory.toggle()
        render()
    }

    @objc private func setHistoryKeep(_ sender: NSMenuItem) {
        Settings.historyKeepDays = sender.tag
        Events.log("history_keep_changed", ["days": sender.tag])
        render()
        pruneHistory("setting_changed")
    }

    // Retention の規則で古い履歴を消す。裏のキューで動き、録音・文字起こしを待たせない
    private static let pruneQueue = DispatchQueue(label: "koe.history-prune", qos: .utility)
    private func pruneHistory(_ reason: String) {
        let keep = Settings.historyKeepDays
        Self.pruneQueue.async {
            let t0 = Date()
            let r = Retention.prune(dir: History.dir, keepDays: keep)
            Events.log("history_pruned", ["reason": reason, "keep_days": keep, "text_days": Retention.textDays(keep),
                                          "removed_audio": r.audio, "removed_text": r.text, "removed_dirs": r.dirs,
                                          "freed_mb": Double(r.bytes) / 1_048_576, "size_mb": Double(r.sizeAfter) / 1_048_576,
                                          "ms": Int(Date().timeIntervalSince(t0) * 1000)])
        }
    }

    @objc private func openHistory() {
        try? FileManager.default.createDirectory(at: History.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(History.dir)
    }

    @objc private func toggleSound() {
        Settings.sounds.toggle()
        render()
    }

    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled { try svc.unregister() } else { try svc.register() }
        } catch {
            showError("ログイン項目の変更に失敗: \(error.localizedDescription)")
        }
        render()
    }

    @objc private func choosePressMode(_ sender: NSMenuItem) {
        Settings.toggleMode = sender.tag == 1
        Events.log("press_mode", ["mode": Settings.toggleMode ? "toggle" : "hold"])
        render()
    }

    static let helpURL = URL(string: "https://github.com/chaspy/koe/blob/main/docs/usage-ja.md")!
    @objc private func openHelp() { NSWorkspace.shared.open(AppDelegate.helpURL) }

    @objc private func exportDiagnostics() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let zip = try Diagnostics.export()
                Events.log("diagnostics_exported")
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([zip])
                    let a = NSAlert()
                    a.messageText = "診断情報をデスクトップに書き出しました"
                    a.informativeText = "\(zip.lastPathComponent) を送ってください。\n入っているもの: 版・機種・設定（秘密の値は伏せた）・動作の記録と速さ・whisper のログ。\n入れていないもの: 文字起こしの本文・録音・辞書の中身。"
                    a.runModal()
                }
            } catch {
                DispatchQueue.main.async { self.fail("診断情報を書き出せませんでした: \(error.localizedDescription)") }
            }
        }
    }

    // 初めて起動したときに、使い方を 3 行で見せる
    private func showWelcomeIfFirstLaunch() {
        guard !Settings.defaults.bool(forKey: "welcomeShown") else { return }
        Settings.defaults.set(true, forKey: "welcomeShown")
        let a = NSAlert()
        a.messageText = "Koe へようこそ"
        a.informativeText = """
        ・\(keyName()) を押している間だけ話し、離すと貼り付けます（ターミナルでは Enter も送ります）
        ・\(keyName()) を素早く 2 回押すとロック録音（ハンズフリー）。もう 1 回押すと終わってテキストに書き出します
        ・押すキー・押し方（トグル）・改行はメニューで変えられます。困ったら「診断情報を書き出す」を送ってください
        メニューバーの吹き出しアイコンが Koe です。
        """
        a.addButton(withTitle: "はじめる")
        a.addButton(withTitle: "使い方を見る")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn { openHelp() }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(WhisperServer.logURL)
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        var symbol = ""
        var image: NSImage = KoeIcon.outline
        var tint: NSColor? = nil
        var line: String
        if let c = current, c.locked {
            image = KoeIcon.filled; tint = .systemOrange
            line = String(format: "ロック録音中（%d 分）… もう一度 \(keyName()) を押すと終わり、テキストに書き出します", Int(Date().timeIntervalSince(c.pressedAt) / 60))
        } else if let c = current, c.toggled {
            image = KoeIcon.filled; tint = .systemRed; line = "録音中…（もう一度 \(keyName()) を押すと終わって貼り付けます）"
        } else if current != nil {
            image = KoeIcon.filled; tint = .systemRed; line = "録音中…"
        } else if let msg = errorMessage {
            symbol = "exclamationmark.triangle"; tint = .systemYellow; line = msg
        } else if let p = downloadProgress {
            tint = .tertiaryLabelColor; line = String(format: "初回のみ: 音声認識モデルをダウンロード中… %.0f%%（約 1.6GB）", p * 100)
        } else if !serverReady {
            tint = .tertiaryLabelColor; line = "モデル読み込み中…"
        } else if cleaning > 0 {
            image = KoeIcon.filled; tint = .systemPurple; line = "LLM で整形中…"
        } else if transcribing > 0 {
            image = KoeIcon.filled; tint = .systemOrange; line = "文字起こし中…"
        } else {
            line = "待機中（\(keyName()) を押している間だけ録音）"
        }
        if secureInput && current == nil {
            symbol = "exclamationmark.triangle"; tint = .systemYellow
            line = "他のアプリがキー入力を保護中のため、右⌘を検知できません（パスワード欄・iTerm の Secure Keyboard Entry など）"
        }
        if !AXIsProcessTrusted() {
            line = PermissionGuide.enabled ? "アクセシビリティの許可が必要です（下の「許可の案内を開く」）" : "アクセシビリティの許可が必要です（システム設定 > プライバシーとセキュリティ）"
            tint = .systemYellow
        } else if PermissionGuide.enabled && PermissionCheck.micDenied {
            line = "マイクの許可が必要です（下の「許可の案内を開く」）"
            tint = .systemYellow
        }
        permissionItem?.isHidden = !PermissionGuide.enabled || PermissionCheck.missingNow().isEmpty
        button.image = symbol.isEmpty ? image : NSImage(systemSymbolName: symbol, accessibilityDescription: "Koe")
        button.image?.accessibilityDescription = "Koe"
        button.contentTintColor = tint
        // 録音中は貼り付け先のアプリ名をメニューバーに出す（どこに入るかを話しながら確認できる）
        if current != nil, let name = NSWorkspace.shared.frontmostApplication?.localizedName {
            button.title = " → \(name)\(Settings.shouldEnter ? "" : "（送信しない）")"
            button.imagePosition = .imageLeft
        } else {
            button.title = ""
        }
        writeState(isBusy ? "busy" : "idle")
        if terminating && !isBusy { terminating = false; NSApp.reply(toApplicationShouldTerminate: true) }
        statusLine?.title = line
        missLine?.title = "マイク: \(recorder.activeName)\(recorder.primaryMuted ? " ※いまミュート中" : "")\(MicNotice.lineSuffix(recorder.notice))"

        enterItem?.state = Settings.autoEnter ? .on : .off
        if current?.locked == true {
            lockItem?.title = "ロック録音を終えてテキストに書き出す"
        } else {
            lockItem?.title = "ロック録音を始める（\(keyName()) を素早く 2 回でも可。もう 1 回押すと終わる）"
        }
        lockItem?.isEnabled = current == nil || current?.locked == true
        lineBreakItem?.state = Settings.lineBreaks ? .on : .off
        warmItem?.state = Settings.warmMic ? .on : .off
        soundItem?.state = Settings.sounds ? .on : .off
        llmItem?.title = "LLM で整形（\(Settings.llmModel)）"
        llmItem?.state = Settings.llmEnabled ? .on : .off
        historyItem?.state = Settings.saveHistory ? .on : .off
        for mi in keepItems { mi.state = mi.tag == Settings.historyKeepDays ? .on : .off }
        clipboardItem?.state = Settings.restoreClipboard ? .on : .off
        improveItem?.state = Settings.improveEnabled ? .on : .off
        improveNowItem?.isEnabled = Settings.improveEnabled && !improver.running
        improveNowItem?.title = improver.running ? "改善中…" : "今すぐ改善する" + (improver.lastRun.map { "（前回: \($0.prefix(40))）" } ?? "")
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        for it in hotkeyMenu?.items ?? [] { it.state = it.tag == Int(Settings.hotkeyKeyCode) ? .on : .off }
        for it in pressModeMenu?.items ?? [] { it.state = (it.tag == 1) == Settings.toggleMode ? .on : .off }
    }

    private var lastUpdateCheck = Date.distantPast
    // manual: 「更新を確認」から押したとき。新しい版が無ければ「最新です」と知らせる
    private func checkUpdate(manual: Bool = false) {
        lastUpdateCheck = Date()
        Updater.check { r in
            DispatchQueue.main.async {
                self.availableUpdate = r
                if let r {
                    self.updateItem.title = "新しい版 v\(r.version) があります（クリックで更新）"
                    self.updateItem.isHidden = false
                    Events.log("update_available", ["version": r.version])
                    self.prepareUpdatePrompt(r)
                } else if manual {
                    self.showError("最新です（v\(Updater.current)）")
                }
            }
        }
    }

    @objc private func checkUpdateNow() { checkUpdate(manual: true) }

    // 新しい版の 1 行の要約を取り、落ち着いたときに聞く（15 秒ごとに見る）
    private func prepareUpdatePrompt(_ r: Updater.Release) {
        if updateSummary?.version != r.version {
            Updater.summary(r) { s in
                DispatchQueue.main.async { self.updateSummary = (r.version, s.line, s.noChanges) }
            }
        }
        guard updatePromptTimer == nil else { return }
        updatePromptTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.maybePromptUpdate() }
    }

    private func maybePromptUpdate() {
        guard updateAlert == nil, let r = availableUpdate, let sum = updateSummary, sum.version == r.version else { return }
        let busy = current != nil || transcribing > 0 || cleaning > 0
        guard UpdatePrompt.shouldPrompt(now: Date(), available: r.version, busy: busy, lastUsed: lastUsedAt,
                                        snoozedUntil: updateSnoozedUntil, noChanges: sum.noChanges) else { return }
        // 同じ版は 24 時間（この起動中）もう聞かない。答えなくても同じ
        updateSnoozedUntil = Date().addingTimeInterval(UpdatePrompt.snooze)
        Events.log("update_prompt", ["version": r.version])
        // モーダルにしない（開いている間も右⌘で話せるように）。フォーカスも奪わない（打っている文字や Enter を吸わない）
        let a = UpdatePrompt.makeAlert(version: r.version, line: sum.line, icon: AppIcon.image, target: self,
                                       now: #selector(updatePromptNow), later: #selector(updatePromptLater))
        updateAlert = a
        UpdatePrompt.present(a)
    }

    @objc private func updatePromptNow() {
        updateAlert?.window.orderOut(nil)
        updateAlert = nil
        Events.log("update_prompt_answer", ["answer": "now"])
        installUpdate()
    }

    @objc private func updatePromptLater() {
        updateAlert?.window.orderOut(nil)
        updateAlert = nil
        Events.log("update_prompt_answer", ["answer": "later"])
    }

    @objc private func installUpdate() {
        guard let r = availableUpdate else { return }
        // 録音中・文字起こし中は待つ
        guard current == nil, transcribing == 0 else { return showError("話し終わってから、もう一度押してください") }
        updateItem.isEnabled = false
        Updater.install(r, progress: { msg in self.updateItem.title = msg },
                        failed: { msg in self.updateItem.isEnabled = true; self.fail(msg); NSWorkspace.shared.open(r.page) })
    }

    @objc private func chooseHotkey(_ sender: NSMenuItem) {
        Settings.defaults.set(sender.tag, forKey: "hotkeyKeyCode")
        hotkeyDown = false
        Events.log("hotkey_changed", ["keyCode": sender.tag])
        render()
    }

    private func keyName() -> String {
        switch Settings.hotkeyKeyCode {
        case 54: return "右⌘"
        case 55: return "左⌘"
        case 61: return "右⌥"
        case 58: return "左⌥"
        case 60: return "右⇧"
        case 56: return "左⇧"
        case 62: return "右⌃"
        case 59: return "左⌃"
        case 63: return "fn"
        default: return "keyCode \(Settings.hotkeyKeyCode)"
        }
    }
}

// Koe.app/Contents/MacOS/Koe --check-update [版]: 公開版に新しい版があるかを出す（動作確認用。版を渡すとその版だとみなす）
if let i = CommandLine.arguments.firstIndex(of: "--check-update") {
    if i + 1 < CommandLine.arguments.count { Settings.defaults.set(CommandLine.arguments[i + 1], forKey: "assumeVersion") }
    let done = DispatchSemaphore(value: 0)
    Updater.check { r in print(r.map { "新しい版 v\($0.version): \($0.dmg)" } ?? "新しい版はありません（今 v\(Updater.current)）"); done.signal() }
    done.wait()
    Settings.defaults.removeObject(forKey: "assumeVersion")
    exit(0)
}

// Koe.app/Contents/MacOS/Koe --diagnostics: 診断情報の zip をデスクトップに書き出してパスを出す
if CommandLine.arguments.contains("--diagnostics") {
    do { print(try Diagnostics.export().path) } catch { print("失敗: \(error.localizedDescription)") }
    exit(0)
}

// Koe.app/Contents/MacOS/Koe --history-prune-dry-run: 今の設定で消すはずの履歴を数えるだけ（消さない。確認用）
if CommandLine.arguments.contains("--history-prune-dry-run") {
    let keep = Settings.historyKeepDays
    let u = Retention.usage(History.dir)
    let r = Retention.prune(dir: History.dir, keepDays: keep, dryRun: true)
    print(String(format: "設定: 録音 %d 日・文字 %d 日（0 = 消さない）/ いまの大きさ %.1f MB・%d ファイル・いちばん古い日 %@", keep, Retention.textDays(keep), Double(u.bytes) / 1_048_576, u.files, u.oldest ?? "なし"))
    print(String(format: "消すはずのもの: 録音 %d・文字 %d・%.1f MB → 残り %.1f MB", r.audio, r.text, Double(r.bytes) / 1_048_576, Double(r.sizeAfter) / 1_048_576))
    exit(0)
}

// Koe.app/Contents/MacOS/Koe --autocorrect "<文>": 自動置き換えの確認用
if let i = CommandLine.arguments.firstIndex(of: "--autocorrect"), i + 1 < CommandLine.arguments.count {
    print(Glossary.autocorrect(CommandLine.arguments[i + 1]))
    exit(0)
}

// Koe.app/Contents/MacOS/Koe --improve-now: 改善ループを 1 回だけ回して結果を出す（動作確認用）
if CommandLine.arguments.contains("--improve-now") {
    let imp = Improver()
    let done = DispatchSemaphore(value: 0)
    imp.onFinish = { print($0); done.signal() }
    DispatchQueue.main.async { imp.runIfNeeded(force: true); if !imp.running { print("動いていません（improveEnabled / improveEndpoint を確認）"); done.signal() } }
    DispatchQueue.global().async { done.wait(); exit(0) }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
