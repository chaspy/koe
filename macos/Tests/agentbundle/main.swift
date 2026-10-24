// test-sources: AgentBundle.swift SelfDiagnosis.swift Redaction.swift ../../Tests/TestSupport.swift
// make test: Sources/Koe/AgentBundle.swift の単体テスト。束に文字起こし・音声・ウィンドウタイトル・クリップボード・
// 機器の名前が入らないことを、目印の文字列と許可したキーで確かめる。一時ディレクトリと合成の値だけを使う
import Foundation

let markerText = "SENTINEL_TRANSCRIPT_話した内容"
let markerTitle = "SENTINEL_WINDOW_TITLE"
let markerClip = "SENTINEL_CLIPBOARD"
let personMic = "山田太郎の AirPods Pro"
let builtIn = "MacBook Pro のマイク"

let recs = (0..<12).map { i in
    DiagRecording(levelDB: -24, noiseDB: i < 9 ? -60 : -90.3, snrDB: 36, zeroRuns: i < 9 ? 0 : 3, zeroRunRatio: i < 9 ? 0 : 0.2,
                  device: i % 2 == 0 ? personMic : builtIn, sampleRate: 16000, channels: 1, fellBack: false, outcome: "pasted")
}
let history: [[String: Any]] = [[
    "id": "20261024-120000", "text": markerText, "raw": markerText, "pasted": markerText, "app": "Terminal",
    "window_title": markerTitle, "title": markerTitle, "clipboard": markerClip, "device": personMic, "alt_device": personMic,
    "audio_seconds": 2.5, "transcribe_ms": 800, "outcome": "pasted", "saved_to": "/Users/someone/Documents/Koe/x.txt",
    "quality": ["level_db": -24.0, "snr_db": 30.0, "note": markerText],
]]
let settings: [String: Any] = [
    "prompt": markerText, "llmPrompt": markerText, "apiKey": "sk-SENTINEL", "improveTokenCommand": "echo SENTINEL",
    "micName": personMic, "fallbackMicName": personMic, "lastClipboard": markerClip, "saveHistory": true,
    "historyKeepDays": 30, "language": "ja", "model": "/Users/someone/models/ggml-large-v3-turbo.bin", "enabledPacks": ["it", "medical"], "NSWindowFrame": markerTitle,
]
let obj = AgentBundle.json(version: "0.9.4 (abc123)", os: "Version 26.2", settings: settings, recordings: recs,
                           history: history, devices: [personMic, builtIn])
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("koe-agentbundle-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: dir) }
do { try AgentBundle.write(obj, to: dir) } catch { check(false, "書き出せる: \(error)") }

// 書き出すのは 2 つのファイルだけ（音声は入れない）
let files = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
check(files == [AgentBundle.jsonName, AgentBundle.readmeName], "ファイルは 2 つだけ: \(files)")

// 目印の文字列・機器の名前がどこにも無い
let json = (try? String(contentsOf: dir.appendingPathComponent(AgentBundle.jsonName), encoding: .utf8)) ?? ""
check(!json.isEmpty, "json がある")
for s in ["SENTINEL", "話した内容", "山田", "太郎", "AirPods", "MacBook Pro のマイク", "Terminal", "/Users/someone"] {
    check(!json.contains(s), "束に入らない: \(s)")
}

// 許可したキーだけ（入れ子も含めて）
func keys(_ v: Any, _ path: String = "") -> [String] {
    if let d = v as? [String: Any] { return d.flatMap { [path + $0.key] + keys($0.value, path + $0.key + ".") } }
    if let a = v as? [Any] { return a.flatMap { keys($0, path + "[].") } }
    return []
}
let parsed = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [:]
let top: Set<String> = ["format", "koe_version", "macos", "input_devices", "settings", "recordings", "history", "findings"]
let rec: Set<String> = ["level_db", "noise_db", "snr_db", "zero_runs", "zero_run_ratio", "device", "sample_rate",
                        "channels", "fell_back", "outcome"]
let fin: Set<String> = ["kind", "affected", "window", "strong"]
let hist = AgentBundle.recordKeys.union(["quality"]).union(AgentBundle.qualityKeys.map { "quality." + $0 })
for k in keys(parsed) {
    let parts = k.split(separator: ".", maxSplits: 1).map(String.init)
    let ok: Bool
    switch parts[0] {
    case _ where parts.count == 1: ok = top.contains(k)
    case "settings": ok = !parts[1].contains(".")   // 値は文字列・数・真偽だけ（下で確かめる）
    case "recordings": ok = rec.contains(String(parts[1].dropFirst(3)))
    case "history": ok = hist.contains(String(parts[1].dropFirst(3)))
    case "findings": ok = fin.contains(String(parts[1].dropFirst(3)))
    default: ok = false
    }
    check(ok, "許可していないキー: \(k)")
}

// 設定: 秘密は ***、本文が入りうるものは伏せる、機器名は記号、NS で始まるものは入れない
let s = (parsed as? [String: Any])?["settings"] as? [String: Any] ?? [:]
check(s["apiKey"] as? String == "***", "秘密: \(s["apiKey"] ?? "nil")")
check(s["prompt"] as? String == "(hidden)", "本文の設定は伏せる")
check(s["lastClipboard"] as? String == "(\(markerClip.count) chars)", "知らない文字列は長さだけ")
check(s["micName"] as? String == AgentBundle.deviceID(personMic), "機器の設定は記号")
check(s["language"] as? String == "ja" && s["model"] as? String == "ggml-large-v3-turbo.bin" && s["historyKeepDays"] as? Int == 30 && s["saveHistory"] as? Bool == true, "安全な値はそのまま")
check(s["enabledPacks"] as? String == "(2 items)" && s["NSWindowFrame"] == nil, "配列は数だけ・NS は入れない")

// 機器の記号: 同じ名前なら同じ、違えば違う、形は mic-xxxxxx
let a = AgentBundle.deviceID(personMic), b = AgentBundle.deviceID(builtIn)
check(a == AgentBundle.deviceID(personMic) && a != b, "機器ごとに決まる: \(a) \(b)")
check(a.range(of: "^mic-[0-9a-f]{6}$", options: .regularExpression) != nil, "形: \(a)")
let devs = (parsed as? [String: Any])?["input_devices"] as? [String] ?? []
check(devs == [a, b], "入力機器も記号: \(devs)")
let r0 = ((parsed as? [String: Any])?["recordings"] as? [[String: Any]])?.first
check(r0?["device"] as? String == a, "録音の機器も記号")

// 所見はゼロ連続が出る。履歴の数値は残る
let fs = (parsed as? [String: Any])?["findings"] as? [[String: Any]] ?? []
check(fs.contains { $0["kind"] as? String == "zeroRuns" }, "所見: \(fs)")
let h0 = ((parsed as? [String: Any])?["history"] as? [[String: Any]])?.first
check(h0?["transcribe_ms"] as? Int == 800 && (h0?["quality"] as? [String: Any])?["snr_db"] as? Double == 30, "履歴の数値")

// README とプロンプト
let readme = (try? String(contentsOf: dir.appendingPathComponent(AgentBundle.readmeName), encoding: .utf8)) ?? ""
check(readme.contains("environment, or a bug in Koe") && readme.contains("chaspy/koe") && readme.contains("Show the draft to the user"), "README の手順")
let p = AgentBundle.prompt(dir: dir)
check(p.contains(AgentBundle.readmeName) && p.contains("chaspy/koe") && p.contains("個人情報を入れない"), "プロンプト")

if failures > 0 { print("\(failures) failure(s)"); exit(1) }
print("agentbundle: ok")
