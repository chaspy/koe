# Reviewing Koe changes

What goes wrong in Koe, and what a reviewer (human or AI) should look for. Every PR is reviewed against this list. When the same kind of finding comes back three times, turn it into a test, a lint, a rule here, or an eval case.

Severity used in reviews:

- **blocker** — would hurt a user or leak something: lost or misdirected text, a dropped permission, a privacy leak, a broken update.
- **should** — a real defect or a missing test for a risky path, but not harmful on its own.
- **nit** — style or wording. Does not block a merge.

## 1. Spoken text leaks (redaction)

Koe hears everything the user says. The text must stay where the user put it.

- `events.jsonl`, logs, diagnostics, crash output and anything sent over the network must **never contain the spoken text** — not the transcript, not the pasted text, not a prefix of it. Counts, lengths, durations and outcome codes are fine.
- History is the only place text is kept, and retention rules (`Retention.swift`, `retention.go`) must still apply to anything new that is stored.
- **Every new event or record field is checked by the reviewer** (adding one is not high risk by itself, so this check is the guard): it holds codes, counts, lengths and times only — no spoken text, no window title, no file path. A finding here is a **blocker**.
- **eval scripts** (`eval/`) read the history. They must not print spoken text to stdout or write it to new files or logs — only numbers, counts, ids and short codes. Check every new `print`, report line and output file. A finding here is a **blocker**.
- New fields in a diagnostics bundle go through redaction (`Redaction.swift`, `diag.go`). Check that a test covers the new field.
- Window titles, app names and file paths of the target app can also be private. Store them only where they are already stored.

## 2. Permissions get dropped

Accessibility and microphone permissions are tied to the app's identity. Losing them means Koe silently stops pasting.

- Signing must stay with the fixed identity (`scripts/sign.sh`; releases use the Developer ID, development builds the self-signed "Koe Code Signing" certificate, see `docs/notes/signing.md`). An ad-hoc signature changes the code hash on every build and macOS drops the Accessibility permission.
- Do not change the bundle id, the executable name, or the install path.
- `Info.plist` usage descriptions and entitlements must stay in place. A new permission is a product decision, not an implementation detail.
- When the permission is missing, Koe must say so (`no_accessibility`) and keep the text on the clipboard — never pretend it pasted.

## 3. Focus is stolen

Koe works on top of whatever the user is typing into. If Koe takes focus, the paste goes to the wrong place.

- New windows, panels, HUDs and alerts must not activate Koe while the user is dictating (non-activating panels, no `NSApp.activate` / `SetForegroundWindow` on the hot path).
- Notifications and prompts appear only when the user is not in the middle of a press-to-talk.
- Check what happens if the user switches apps while transcription is running (`target_changed`).

## 4. The paste does not arrive

- The text must reach the app that was frontmost when the key was pressed — or not be pasted at all (keep it on the clipboard and log the outcome).
- The user's clipboard is restored after pasting, without racing the paste.
- Nothing slow (network, model load, large file reads) runs between "transcription done" and "paste".
- Every new early return in the press → record → transcribe → paste path logs an outcome, so that missed pastes can be counted.

## 5. Surprising defaults

- New features ship **off by default** behind a setting, unless the PR says it was agreed to turn it on.
- Do not change existing defaults, hotkeys, sounds or menu structure silently. Say it in the PR and in its changelog fragment `changelog.d/<PR number>-<name>.md` (a PR never edits `CHANGELOG.md`; see `changelog.d/README.txt`).
- Migrations of the config file keep old keys working.

## 6. Private words in the public tree

This repository is published as-is. Every file in the tree is public.

- No company names, internal product or team names, internal channel or repository names, people's names or user ids, internal URLs, or personal paths outside examples.
- Term packs (`packs/`) only hold general technical terms. Company-specific words go in a user's own organization glossary.
- Test data and examples use made-up text.

## 7. Mac and Windows drift

- A behavior change on one platform says what happens on the other ("Windows: no changes", or a follow-up).
- Shared formats (config keys, `events.jsonl` fields, history records, pack format) stay the same on both.

## 8. Updates, release and CI

- The update check must never install or replace anything without the user's action, and must fail quietly when offline.
- The in-app update replaces Koe only after `UpdateVerify` accepts the downloaded app's signature (Developer ID and team). Skipping, weakening or bypassing that check (or the `Updater` code that calls it) is a **blocker**; any change to it is high risk (`.github/risk-rules.txt`).
- A version comparison change needs a test (`Tests/update`, `update_test.go`).
- CI workflows run on a paid account: every job has `timeout-minutes`, triggers are manual unless agreed otherwise, and the PR states the expected minutes × price.

## How a review is done

1. Rebase check: the PR is on the latest `main` and GitHub shows it as mergeable. If not, ask the implementer to rebase first.
2. Run the checks for what the PR touches and paste the output in the review:
   - `kagami check --format agent-brief` — `gate=pass`, or each remaining finding explained in the PR body (a false positive is filed with `kagami feedback`, never silenced with a suppression comment)
   - `python3 scripts/changelog.py check` — the PR adds a fragment in `changelog.d/` and does not touch `CHANGELOG.md`
   - macOS: `make -C macos test` (it runs every `macos/Tests/<name>/main.swift` with the sources on its `// test-sources:` line; a new test does not edit the Makefile) and `swift build -c release`
   - Windows: `cd windows && go test ./core/... && GOOS=windows go vet ./...`
   - `python3 scripts/pr_risk.py --base origin/main --head <branch>` for the risk label
3. Findings use the severities above. low and mid PRs are merged by the reviewer when there is no blocker or should; high PRs get a decision card.

### Decision card (high risk, or anything handed to the maintainer)

Post one comment on the PR in this shape, short enough to read on a phone. The maintainer decides from the card alone.

```
## Maintainer decision card
- 種類: <what kind of change, and which files or rules it touches>
## 1 画面要約
1. <what the PR does, one line>
2. <...>
3. <the finding or the risk that needs a human>
4. <...>
5. 推奨: <merge / hold / change X>

**Decide:** <one question with yes/no, or A/B>
**Why it needs you:** <which high-risk rule, in one line>
**Risks if merged:** <1–3 bullets: what breaks, for whom, how likely>
**Risks if not merged:** <1 bullet>
**Checked:** <what the reviewer verified, one line>
**Not checked:** <what nobody could verify here>
**Rollback:** <one line>
**Reviewer recommends:** <merge / hold / change X>
```

No diff excerpts, transcripts or personal data. Two separate decisions get two cards.

## What the PR must show

The PR template asks for: how it was tested (commands and their output), the risk, and how to roll back. A PR without test output for a changed behavior gets a **should** finding.
