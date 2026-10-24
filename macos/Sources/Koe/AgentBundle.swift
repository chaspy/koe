import Foundation

// 自己診断（#211）の「Claude Code で詳しく調べる」で書き出す束: koe-diagnose.json と README-for-agents.md。
// 利用者の手元の Claude Code に読ませる。入れるのは数値・機器名・結果の名前・伏せた設定・版だけで、
// 文字起こし・音声・ウィンドウタイトル・クリップボードの中身は入れない（許可したキーだけを写す。Tests/agentbundle）
enum AgentBundle {
    static let jsonName = "koe-diagnose.json"
    static let readmeName = "README-for-agents.md"

    // 履歴の 1 件から写す欄（数値と結果の名前だけ）。ここに無い欄（text・raw・pasted・app・window など）は写さない
    static let recordKeys: Set<String> = ["audio_seconds", "voiced_seconds", "transcribe_ms", "release_to_paste_ms",
                                          "stop_ms", "key_up_lag_ms", "load1", "peak", "outcome", "dropped",
                                          "visible_ms", "communication_impact"]
    static let qualityKeys: Set<String> = ["level_db", "noise_db", "snr_db", "speech_s", "clip_ratio", "brightness"]
    // 文字列のまま出してよい設定（機器・キー・音の名前など）。ほかの文字列は長さだけにする
    static let plainStringSettings: Set<String> = ["language", "pressMode", "startSound", "stopSound", "failSound",
                                                   "improveProvider", "improveModel", "llmModel"]
    // 機器の名前には人名が入りうる（「○○の AirPods」）ので、名前ごとに決まる短い記号に置き換える
    static let deviceSettings: Set<String> = ["micName", "fallbackMicName"]

    /// 同じ名前なら毎回同じ "mic-xxxxxx"（FNV-1a 64 bit の上 24 bit）。名前は戻せない
    static func deviceID(_ name: String) -> String {
        guard !name.isEmpty else { return "" }
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "mic-" + String(format: "%06x", h >> 40)
    }

    static func setting(_ key: String, _ value: Any) -> Any {
        if Redaction.secretWords.contains(where: { key.lowercased().contains($0) }) { return "***" }
        if Redaction.privateKeys.contains(key) { return "(hidden)" }
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n
        case let s as String where deviceSettings.contains(key): return deviceID(s)
        case let s as String where key == "model": return (s as NSString).lastPathComponent   // パスにはユーザー名が入る
        case let s as String: return plainStringSettings.contains(key) ? s : "(\(s.count) chars)"
        case let a as [Any]: return "(\(a.count) items)"
        case let d as [String: Any]: return "(\(d.count) entries)"
        default: return "(hidden)"
        }
    }

    static func record(_ r: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for k in recordKeys {
            guard let v = r[k] else { continue }
            if k == "outcome" { if let s = v as? String { out[k] = s } } else if v is NSNumber { out[k] = v }
        }
        if let q = r["quality"] as? [String: Any] {
            out["quality"] = q.filter { qualityKeys.contains($0.key) && $0.value is NSNumber }
        }
        return out
    }

    static func diagRecording(_ r: DiagRecording) -> [String: Any] {
        var out: [String: Any] = ["zero_runs": r.zeroRuns, "zero_run_ratio": r.zeroRunRatio, "device": deviceID(r.device),
                                  "sample_rate": r.sampleRate, "channels": r.channels, "fell_back": r.fellBack,
                                  "outcome": r.outcome]
        if let v = r.levelDB { out["level_db"] = v }
        if let v = r.noiseDB { out["noise_db"] = v }
        if let v = r.snrDB { out["snr_db"] = v }
        return out
    }

    static func json(version: String, os: String, settings: [String: Any], recordings: [DiagRecording],
                     history: [[String: Any]], devices: [String]) -> [String: Any] {
        var s: [String: Any] = [:]
        for (k, v) in settings where !k.hasPrefix("NS") { s[k] = setting(k, v) }
        return [
            "format": "koe-diagnose/1",
            "koe_version": version,
            "macos": os,
            "input_devices": devices.map(deviceID),
            "settings": s,
            "recordings": recordings.map(diagRecording),
            "history": history.map(record),
            "findings": SelfDiagnosis.findings(recordings).map {
                ["kind": $0.kind.rawValue, "affected": $0.affected, "window": $0.window, "strong": $0.strong] as [String: Any]
            },
        ]
    }

    /// dir に 2 つのファイルを書く
    static func write(_ object: [String: Any], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent(jsonName))
        try readme.write(to: dir.appendingPathComponent(readmeName), atomically: true, encoding: .utf8)
    }

    /// クリップボードに入れる、Claude Code への頼み方
    static func prompt(dir: URL) -> String {
        "\(dir.appendingPathComponent(readmeName).path) を読んで、Koe の聞き取りや貼り付けがうまくいかない原因を調べて。" +
        "Koe 本体の不具合と分かったら、chaspy/koe に Issue を立てる案を作って（本文に話した内容・個人情報を入れない。立てる前に私に見せて）"
    }

    static let readme = """
    # Koe diagnostics for agents

    This folder was written by Koe (a macOS voice-input app) from its menu 「診断する…」 →
    「Claude Code で詳しく調べる」. It contains numbers only: no transcripts, no audio, no window titles,
    no clipboard content. Settings that could hold secrets or text are hidden.

    ## What to do
    1. Read `koe-diagnose.json`.
    2. Decide first: **is this the user's environment, or a bug in Koe itself?**
       Most problems are the environment (microphone mode, which microphone, room noise, permissions).
    3. Explain the likely cause to the user in plain words and suggest one thing to try at a time.
       Word causes as suspicions unless the numbers clearly show them.
    4. Only if it looks like a bug in Koe: draft a GitHub issue for the **public** repository `chaspy/koe`
       with numbers and steps to reproduce. Never include what the user said, transcripts, audio, names,
       company or project information. **Show the draft to the user and let them decide before filing.**

    ## Fields
    - `koe_version`, `macos`: versions.
    - `input_devices`, `recordings[].device`, `settings.micName`: devices as `mic-xxxxxx`. Device names can contain
      a person's name, so each name is replaced by a short hash: the same device always has the same id.
    - `settings`: Koe's settings. Secrets are `***`; strings that may contain text are replaced by their length.
    - `recordings` (oldest first, up to 50): per recording
      - `level_db`: speech level (dBFS). Below about -36 is quiet.
      - `noise_db`: noise floor (dBFS). About -90 is not a quiet room: it is digital silence, usually from noise removal.
      - `snr_db`: speech minus noise. A sudden *rise* together with `noise_db` near -90 is not an improvement.
      - `zero_runs`, `zero_run_ratio`: runs of exactly-zero samples (≥ 50 ms) inside the voiced part, and their share.
      - `device`, `sample_rate`, `channels`, `fell_back` (the preferred mic gave nothing and a spare one was used).
      - `outcome`: `pasted`, `no_accessibility`, `target_changed`, `no_voice`, `mic_silent`, `error`, …
    - `history` (only when 「録音と結果を保存」 is on): timings in ms/s, `peak`, `quality`, `outcome`.
    - `findings`: what Koe's own detectors flagged (`zeroRuns`, `lowLevel`, `noisy`, `device`, `paste`),
      with how many of the last `window` recordings showed it.

    ## Known causes and suspects
    - **Exact-zero runs / noise floor near -90 dB**: the macOS microphone mode 「声を分離」(Voice Isolation) or a
      noise-removal app is suspected (not confirmed). Ask the user to switch the mic mode back to 「標準」 and talk a few times.
    - **Low level**: earphone/headset mics, or the mic far from the mouth. Bluetooth mics also lower quality.
    - **Low SNR**: a noisy room or office.
    - **Device changes / fell back**: the chosen mic disconnected or a MacBook lid is closed.
    - **Paste failures** (`no_accessibility`, `target_changed`): the Accessibility permission (often lost after the app's
      signature changed with an update) or the window changed while Koe was transcribing.
    - **Menu icon not visible**: it may be hidden behind the notch on a MacBook.
    """
}
