# macOS server lifetime (#212)

The silent exit's original cause is still unknown. This change limits its effects:

- Koe records the parent and server PID, kernel start time, and executable path in
  `Application Support/Koe/servers/`. These operational ownership records are not
  events and are not included in diagnostics.
- A second invocation of the same Koe executable runs only an internal watcher.
  Its stdin is a pipe owned by Koe. Normal close, a crash, or SIGKILL closes the
  pipe; the watcher sends TERM to the matching server, then KILL after two seconds
  if it still matches. No process-name scan or port-based killing is used.
- At launch, recorded servers whose parent no longer matches are stopped before
  another server starts. Unrecorded servers (including older releases) are left
  alone. A crash in the short interval before the ownership record is written
  cannot be recovered this way.
- A `Koe/running` marker is removed on normal termination. A leftover marker causes
  one notice on the next launch, with a diagnostics export button. Existing quit
  events (#200) remain available in the diagnostics export. It does not claim to
  know why Koe stopped.
- `unclean_shutdown_detected` and `orphan_server_killed` (count only) are events.
  LaunchAgent auto-restart is a separate, high-risk follow-up; Windows is unchanged.

## Isolated check

```sh
cd macos
nice -n 15 swift build -c release -j 4
bash Tests/server-lifecycle/run.sh
```

This starts the built Koe **only in watcher mode**, a dedicated fixture parent,
plus `/bin/sleep` as a fake server. It kills only that fixture parent, checks that
its child exits within five seconds, checks normal pipe closure, and tests marker
reset and stale PID protection. It uses a unique temporary directory and never
starts the app, accesses the user's running marker, microphone, model or server.
The normal unit suite tests the same path with the test executable as the watcher.
The actual startup alert needs a separate disposable app session for visual QA;
do not kill the user's running Koe to exercise it.
