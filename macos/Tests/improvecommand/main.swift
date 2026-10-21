// test-sources: ImproveCommand.swift
import Foundation

func resolve(_ name: String, files: Set<String>, login: String? = nil) -> ImproveCommand.Match? {
    ImproveCommand.resolve(name, home: "/Users/example", executable: { files.contains($0) }, lookup: { _ in login })
}
precondition(resolve("/custom/tool", files: ["/custom/tool"])?.location == "absolute")
precondition(resolve("/missing", files: [], login: "/other") == nil)
for (dir, label) in ImproveCommand.directories(home: "/Users/example") {
    precondition(resolve("tool", files: [dir + "/tool"])?.location == label)
}
precondition(resolve("tool", files: ["/Users/example/.local/bin/tool", "/opt/homebrew/bin/tool"])?.location == "local")
precondition(resolve("tool", files: ["/custom/tool"], login: "/custom/tool\n")?.location == "login_path")
precondition(resolve("tool", files: [], login: "tool: shell function") == nil)
precondition(resolve("tool", files: []) == nil)
precondition(ImproveCommand.token("A=b\t'/custom/my tool' -p")?.program == "/custom/my tool")
precondition(ImproveCommand.token("/custom/my\\ tool -p")?.program == "/custom/my tool")
precondition(ImproveCommand.token("'unclosed") == nil)
precondition(ImproveCommand.token("'/custom/tool=v2' -p")?.program == "/custom/tool=v2")
let command = "A=b 'tool' --flag 'argument'"
let token = ImproveCommand.token(command)!
precondition(command.replacingCharacters(in: token.range, with: ImproveCommand.quote("/some/tool")) == "A=b '/some/tool' --flag 'argument'")
precondition(ImproveCommand.path(home: "/Users/example", inherited: "/extra").contains(":/extra:"))
var failures = ImproveFailures()
let now = Date(timeIntervalSince1970: 100000)
for _ in 0..<2 { failures.record(127); precondition(!failures.takeNotice(now: now)) }
failures.record(127)
precondition(failures.takeNotice(now: now))
failures.record(1)
precondition(!failures.takeNotice(now: now.addingTimeInterval(86399)))
precondition(failures.takeNotice(now: now.addingTimeInterval(86400)))
failures.record(0)
precondition(failures.consecutive == 0)
precondition(!failures.takeNotice(now: now.addingTimeInterval(172800)))
for _ in 0..<3 { failures.record(127) }
precondition(!failures.takeNotice(now: now.addingTimeInterval(86401)))
print("improvecommand: passed")
