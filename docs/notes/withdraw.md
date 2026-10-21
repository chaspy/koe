# Withdrawing a broken release

The rule stays **fix forward**: a broken release is fixed by publishing the next version, not by going back. This page covers the time until that version is out:

1. stop the broken version from reaching more people, and
2. tell people who already installed it how to go back by hand.

It describes the current setup, where every release on GitHub Releases is the one stable channel. A separate channel for early builds ("latest", published as pre-releases) is being designed; this page will cover it once that design is settled. Once that channel exists, steps 1 and 5 below no longer work (a pre-release would still reach that channel), and withdrawing will mean deleting the release and its tag instead.

In the examples, `0.8.0` is the broken version, `0.7.0` the previous one and `0.8.1` the fix. Replace them with the real versions.

## How Koe finds updates

Both the macOS and the Windows app send `HEAD https://github.com/chaspy/koe/releases/latest` without following the redirect. They read the version from the `Location` header (`/releases/tag/vX.Y.Z`) and offer it only when it is **newer** than the running version. Neither app ever moves to an older version on its own.

- The app checks at start, once a day, and when the menu is opened (at most once a minute).
- Once an app has offered a version, it remembers that offer until it restarts:
  - macOS: the 「新しい版」 menu item stays.
  - Windows: the tray item stays, and clicking it still installs that version.
- The download URLs are fixed by the version: `/releases/download/v0.8.0/Koe-0.8.0.dmg` and `Koe-0.8.0-windows-x64.zip`. So **an app that was already offered the broken version can still install it as long as its files are on the release**. That is why step 4 below deletes them.

## Stop the broken version

```sh
# 1. Take the broken release off "Latest" (the tag and the files stay)
gh release edit v0.8.0 -R chaspy/koe --prerelease

# 2. Make the previous release "Latest" again
gh release edit v0.7.0 -R chaspy/koe --latest

# 3. Check what the apps will see: the redirect must point at the previous version
curl -sI https://github.com/chaspy/koe/releases/latest | grep -i '^location'
#   location: https://github.com/chaspy/koe/releases/tag/v0.7.0

# 4. Delete the broken version's files, so apps that already offered it cannot install it
gh release delete-asset v0.8.0 Koe-0.8.0.dmg -R chaspy/koe -y
gh release delete-asset v0.8.0 Koe-0.8.0-windows-x64.zip -R chaspy/koe -y

# 5. Put a short note above the broken release's notes: write the notice from "Notice to users" below into withdrawn.md first.
#    --notes-file replaces the notes, so keep the old text
gh release view v0.8.0 -R chaspy/koe --json body -q .body > old-notes.md
cat withdrawn.md old-notes.md > notes.md
gh release edit v0.8.0 -R chaspy/koe --notes-file notes.md
```

What happens then:

| Who | macOS | Windows |
|---|---|---|
| Still on 0.7.0, never offered 0.8.0 | Nothing is offered | Nothing is offered |
| Already on 0.8.0 | Stays on 0.8.0 until 0.8.1 is offered | Same |
| On 0.7.0, offered 0.8.0 before step 1 | After the next check the menu item does nothing when clicked. Before that, or from an update dialog that is already open, installing should fail with "dmg を開けませんでした" (after step 4; not yet tried) and open the release page | The tray item stays. Clicking it fails with a download error (after step 4) and opens the release page |

Without step 4, the last row installs the broken version.

## Publish the fix

Publish 0.8.1 as usual. The newest release becomes "Latest" by default; check it with the `curl` from step 3, and if the redirect still points at 0.7.0, run `gh release edit v0.8.1 -R chaspy/koe --latest`. Every app on 0.7.0 or 0.8.0 is then offered 0.8.1 at its next check. Then either delete the 0.8.0 release or leave it as a pre-release with the note.

## Notice to users

Post this where users read release news, and at the top of the broken release's notes. Adjust the versions and the symptom.

> **Koe 0.8.0 has a problem** (one line on what goes wrong). A fixed version is on its way, and Koe will offer it in its menu as usual. You do not need to do anything.
>
> If you need to go back now:
> - **macOS**: download `Koe-0.7.0.dmg` from https://github.com/chaspy/koe/releases/tag/v0.7.0. Quit Koe and replace Koe in your Applications folder with the one in the dmg. If macOS blocks it the first time, open System Settings → Privacy & Security and click "Open Anyway".
> - **Windows**: download `Koe-0.7.0-windows-x64.zip` from the same page. Quit Koe and extract the zip over your Koe folder, replacing the files. If Windows SmartScreen warns, click "More info" → "Run anyway".

Notes for whoever sends it:
- **macOS permissions**: from 0.9.0 on, releases are signed with Koe's Apple Developer ID (see [signing.md](signing.md)); 0.5.0 to 0.8.0 were signed with the self-signed "Koe Code Signing" certificate, and 0.4.x and earlier with yet another one. Going back keeps the Accessibility and Microphone permissions only when the designated requirement stays the same, so from a 0.9.x or later version, point people only to another Developer ID version (0.9.0 or later). Going back to 0.8.0 or earlier needs both permissions again, the same as going back to 0.4.x. Check the version you point people to with `codesign -d -r-`: its requirement must match the broken version's.
- **macOS Gatekeeper**: an app replaced by hand from a downloaded dmg is quarantined, so "Open Anyway" is needed once while Koe is not notarized. Updates from the menu do not need it: the dmg Koe downloads itself carries no quarantine attribute, and since #177 the in-app update does not touch extended attributes (it checks the new app's signature before replacing Koe).
- **Windows leftovers**: extracting an older zip over the folder leaves files that only the newer version had. The in-app update copies the same way (it never deletes files), so this is not new.
- **Settings and history**: no version migrates its settings or history format. An older version is expected to ignore keys it does not know, but this has not been tested.

## Rehearsing

The update source can be pointed at another public repository, so the steps above can be tried without touching the real releases:
- macOS: `defaults write io.github.chaspy.koe updateRepo <owner>/<test-repo>`, then menu → 更新を確認, or `Koe.app/Contents/MacOS/Koe --check-update <version>`.
- Windows: `"updateRepo": "<owner>/<test-repo>"` in config.json.

Remove the setting afterwards. Three things have not been checked yet:
- how quickly the `/releases/latest` redirect follows steps 1–2, given GitHub's caching;
- the macOS message when the dmg has been deleted (the download gets a 404 page, which should then fail to mount);
- whether going back with the same certificate really keeps the macOS permissions on a real Mac.
