// test-sources: QuitLog.swift Redaction.swift ../../Tests/TestSupport.swift
import Foundation

check(QuitLog.source(menu: true, appleEvent: false, logout: false, system: false) == "menu", "menu")
check(QuitLog.source(menu: false, appleEvent: true, logout: false, system: false) == "apple_event", "Apple event")
check(QuitLog.source(menu: false, appleEvent: true, logout: true, system: false) == "logout", "logout priority")
check(QuitLog.source(menu: false, appleEvent: false, logout: false, system: true) == "system", "SIGTERM")
check(QuitLog.source(menu: false, appleEvent: false, logout: false, system: false) == "unknown", "no evidence")
let launch = #"{"outcome":"launch"}"#
let quit = #"{"outcome":"app_quit","source":"apple_event","sender_bundle":"org.example.sender","busy":true}"#
check(QuitLog.previousQuitUnrecorded(state: "stopped\n", events: launch), "legacy stopped session")
check(QuitLog.previousQuitUnrecorded(state: "stopped", events: ""), "missing log")
check(QuitLog.previousQuitUnrecorded(state: "stopped", events: quit + "\n" + launch), "old quit cannot mask missing quit")
check(QuitLog.previousQuitUnrecorded(state: "stopped", events: launch + "\ninvalid"), "malformed tail")
check(!QuitLog.previousQuitUnrecorded(state: "stopped", events: launch + "\n" + quit + "\ninvalid"), "recorded quit")
for state in [nil, "idle", "busy"] as [String?] {
    check(!QuitLog.previousQuitUnrecorded(state: state, events: launch), "only stopped is counted")
}
let redacted = Redaction.redactEvent(quit) ?? ""
let fields = (try? JSONSerialization.jsonObject(with: Data(redacted.utf8))) as? [String: Any] ?? [:]
check(Set(fields.keys) == ["outcome", "source", "sender_bundle", "busy"], "diagnostics fields")
check(fields["sender_bundle"] as? String == "org.example.sender", "bundle id survives redaction")
check(fields["busy"] as? Bool == true, "busy survives redaction")
if failures > 0 { exit(1) }
print("quitlog: ok")
