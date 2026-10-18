# Publishing a release

Releases are made by the maintainer only, with `scripts/release/release.sh` on a Mac set up as in [signing.md](signing.md#set-up-a-mac-for-releases-once).

## What a release is
- **Development repository** (`chaspy/koe-dev`): a commit `release: X.Y.Z` on `main` that only sets `CFBundleShortVersionString` in `macos/Info.plist` and turns `## Unreleased` in `CHANGELOG.md` into `## X.Y.Z — <date>`; tag `vX.Y.Z`.
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

1. **Preconditions.** Local `main` equals `origin/main` and the checkout is clean (with `--publish`); `gh` is logged in; the version is newer than `Info.plist`'s and its tag exists on neither repository; the Developer ID identity, the notarytool profile, the denylist and the static whisper-server exist. Everything missing is listed at once.
2. **Tests**: macOS (`make test`, `swift build -c release -j 4`), Windows (`go test ./core/...`, `GOOS=windows go vet ./...`), `eval`, and `scripts/release`.
3. **Dev release commit** (see above). Any other change stops the script.
4. **Scrub**: `scripts/release/scrub.sh` checks what the public repository would gain (lines added or changed since public `main`, names of new files, strings in changed binary files). It looks for the words in `~/.config/koe/release-denylist.txt` (kept outside the repository; one case-insensitive regular expression per line) and for e-mail addresses, chat / document links, private IP addresses, internal host names, tokens and private keys (and gitleaks, when installed), and home directory paths. It prints only `path:line: category`, never the text. Fix the hit in a normal pull request and run the release again. A false positive of a generic pattern can be allowed by adding the printed `path:hash` to `scripts/release/scrub-allow.txt` (in a reviewed pull request, with the reason); denylist hits cannot be allowed.
5. **Builds**: `make dist` (Developer ID, hardened runtime; see signing.md), then `scripts/notarize.sh` (notarize, staple, Gatekeeper check; skipped with `--no-notarize`), and `windows/build.sh`. Heavy steps run under `nice -n 15` with 4 jobs.
6. **Public commit** with `git commit-tree <dev tree> -p <public main> -m "Koe X.Y.Z"`; the script checks that the trees are identical.
7. **Publish** (`--publish` only): push the dev commit to `origin/main` (fails if `main` moved; rerun), the public commit to `chaspy/koe` `main`, tag both, and `gh release create`. The dry run prints these commands instead.
8. **Check**: download the published dmg (the dry run uses the local one), compare its checksum, and run `codesign --verify --deep --strict`, the Developer ID checks, `spctl -a -vvv -t install` on the dmg and `spctl -t exec` on the app (with `--no-notarize` spctl is expected to reject; its result is printed but does not stop the script).

If something fails after step 7 started, finish the remaining commands of step 7 by hand (they are printed by a dry run) rather than rerunning the script: the version is already used.
