# Publishing a release

Releases are made by the maintainer only, with `scripts/release/release.sh` on a Mac set up as in [signing.md](signing.md#set-up-a-mac-for-releases-once).

## What a release is
- **Development repository** (`chaspy/koe-dev`): a commit `release: X.Y.Z` on `main` that only sets `CFBundleShortVersionString` in `macos/Info.plist` and folds the `changelog.d/` fragments into `## X.Y.Z — <date>` of `CHANGELOG.md` (deleting them; `scripts/changelog.py release`); tag `vX.Y.Z`.
- **Public repository** (`chaspy/koe`): one commit per release on `main`, message `Koe X.Y.Z`, whose tree is exactly the tree of the dev release commit and whose parent is the previous public commit; tag `vX.Y.Z` on it.
- **GitHub Release** `vX.Y.Z` on `chaspy/koe`, title `Koe X.Y.Z`. The body is `## Changes` with the CHANGELOG section of the version (`### Repository` / `### macOS` / `### Windows`) and `## Install` from `scripts/release/install-notes.md`. Files: `Koe-X.Y.Z.dmg` and `Koe-X.Y.Z-windows-x64.zip`.

The apps depend on these names: the updaters read the version from where `releases/latest` redirects to (`/releases/tag/vX.Y.Z`), download `releases/download/vX.Y.Z/Koe-X.Y.Z.dmg` (with `Koe.app` at the top of the dmg) or `Koe-X.Y.Z-windows-x64.zip`, and show the first item of their platform from `CHANGELOG.md` at the public tag (`- No changes.` means the update is not offered in a prompt). Keep them when changing the script.

## Steps
```sh
# needs: the Developer ID identity, the notarytool profile "koe",
# ~/.config/koe/release-denylist.txt, gh login, the static whisper-server
scripts/release/release.sh 0.9.0              # dry run: all steps, nothing pushed
scripts/release/release.sh 0.9.0 --publish    # the real thing
```
Run the dry run first; it stops at the first problem. It works in its own worktree of `origin/main` under `~/Library/Caches/koe-release/X.Y.Z/` (the dmg, zip, release notes and `SHA256SUMS` are in `out/`), so your checkout is not changed. `--no-notarize` builds a Developer ID signed dmg without notarizing it (when the notarytool profile cannot be set up yet); it works with `--publish`, and the log and the release notes' Install section say the dmg is not notarized (releases up to 0.8.0 were not notarized either). `--ref <rev>` dry-runs another revision; it does not work with `--publish`.

`--mac-only` makes a macOS-only release (the Windows app stays on the previous version): no Windows zip is built or attached, `scripts/changelog.py release --hold Windows` writes `### Windows` / `- No changes.` and leaves the Windows entries in their `changelog.d/` fragments for the next release with Windows, and the Install section says there is no Windows build. The Windows app checks `releases/latest` and offers an update only when that release has `Koe-X.Y.Z-windows-x64.zip` (`windows/update_windows.go`, `core.ErrNoWindowsAsset`), so it does not offer this version. While a macOS-only release is the latest, Windows users on an older version are not offered the previous Windows build either; they get the next release that has a zip.

1. **Preconditions.** Local `main` equals `origin/main` and the checkout is clean (with `--publish`); `gh` is logged in; the version is newer than `Info.plist`'s and its tag exists on neither repository; the Developer ID identity, the notarytool profile, the denylist and the static whisper-server exist. Everything missing is listed at once.
2. **Tests**: macOS (`make test`, `swift build -c release -j 4`), Windows (native cgo tests and MinGW cgo cross-vet; see [audio-core builds](audio-core-builds.md)), `eval`, `scripts` and `scripts/release`.
3. **Dev release commit** (see above). `scripts/changelog.py release X.Y.Z` folds the fragments in PR-number order (sections Repository → macOS → Windows; an app with no fragment gets `- No changes.`) and prints the line each app's update prompt will show — the first item of its section. Any change other than `CHANGELOG.md`, `macos/Info.plist` and deleted fragments stops the script. Check `python3 scripts/changelog.py preview` before the release; to put a more important item first, rename its fragment to start with `0-` (it then sorts before the PR numbers).
4. **Scrub**: `scripts/release/scrub.sh` checks what the public repository would gain (lines added or changed since public `main`, names of new files, strings in changed binary files). It looks for the words in `~/.config/koe/release-denylist.txt` (kept outside the repository; one case-insensitive regular expression per line) and for e-mail addresses, chat / document links, private IP addresses, internal host names, tokens and private keys (and gitleaks, when installed), and home directory paths. It prints only `path:line: category`, never the text. Fix the hit in a normal pull request and run the release again. A false positive of a generic pattern can be allowed by adding the printed `path:hash` to `scripts/release/scrub-allow.txt` (in a reviewed pull request, with the reason); denylist hits cannot be allowed.
5. **Builds**: `make dist` (Developer ID, hardened runtime; see signing.md), then `scripts/notarize.sh` (notarize, staple, Gatekeeper check; skipped with `--no-notarize`), and `windows/build.sh`. Heavy steps run under `nice -n 15` with 4 jobs.
6. **Public commit** with `git commit-tree <dev tree> -p <public main> -m "Koe X.Y.Z"`; the script checks that the trees are identical.
7. **Publish** (`--publish` only): push the dev commit to `origin/main` (fails if `main` moved; rerun), the public commit to `chaspy/koe` `main`, tag both, and `gh release create`. The dry run prints these commands instead.
8. **Check**: download the published dmg (the dry run uses the local one), compare its checksum, and run `codesign --verify --deep --strict`, the Developer ID checks, `spctl -a -vvv -t install` on the dmg and `spctl -t exec` on the app (with `--no-notarize` spctl is expected to reject; its result is printed but does not stop the script).

If something fails after step 7 started, finish the remaining commands of step 7 by hand (they are printed by a dry run) rather than rerunning the script: the version is already used.

## Accessibility re-grant notice (macOS)

When a release changes the signing identity, add a `Re-grant:` item under the
`### macOS` section of its changelog fragment, for example:

```markdown
### macOS
- Re-grant: Signing identity changes; allow Accessibility again after updating.
```

The macOS updater scans the whole target version's macOS section, even when this
item is not first. It shows a separate, untruncated Japanese warning before
installation, including removing Koe with − and adding it again with + if the
switch already looks on. The menu update action also shows this confirmation.
Releases without the marker keep their usual summary. This marker does not change
signing, grant permissions, or reset TCC. Older clients without marker support do
not recognize it; it cannot retrofit a pre-update warning into an installed old
version. Include the warning in the first item too when supporting those clients.
