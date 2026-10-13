# Contributing to Koe

## Term packs (`packs/`)

Term packs are glossaries for a field, shipped with the app and turned on from the menu (用語パック). They help in three places:

1. **whisper's initial prompt** — terms you actually use are put in the prompt, so they are spelled right more often
2. **autocorrect** — known misrecognitions are replaced before pasting
3. **the note for the receiving AI** (`~/.claude/koe-voice-glossary.md`) — Claude reads misrecognized words correctly

### Format

One term per line. After a tab, misrecognized forms separated by `／`.

```
プルリクエスト	プロリクエスト／フルリクエスト
マージ	~マジ
GitHub
```

- **A plain form** is an unambiguous misrecognition. Koe replaces it with the term before pasting (but not inside a longer katakana/latin word).
- **A form with `>(…)`** is replaced only when one of the listed words follows it: `マジ>(され|し|する)` turns 「マジされた」 into 「マージされた」 but leaves 「マジで」 alone. Use this to make an ambiguous form safe in the contexts where it is clearly the term.
- **A form starting with `~`** is ambiguous — it is also a normal word (マジ = "seriously"). Koe never replaces it; it only tells the receiving AI that it may mean the term.
- Lines starting with `#` are comments. The first line `# Koe 用語パック: <title>` is the title shown in the menu.

### What to add

- **Terms**: words people in that field say often and that should be spelled a certain way. Prefer the spelling the community uses.
- **Misrecognitions**: only forms you have **actually seen** Koe produce. Do not guess.
- **Not misrecognitions**: plain readings in katakana (イシュー for Issue) are not errors — do not add them as aliases.
- **No company-specific words** (internal product names, people, URLs). Those belong in your organization glossary (`orgGlossary`), not in a public pack.

### Checking

```bash
# after make install
~/Applications/Koe.app/Contents/MacOS/Koe --autocorrect "プロリクを作ってマジでマージして"
# → プルリクを作ってマジでマージして  (プロリク fixed, マジ left alone)
```

If you change a pack's effect on accuracy, compare before/after on your own history with `eval/koe_bench.py` (blinded comparison).

### New packs

Add `packs/<id>.txt`. Keep it focused on one field (e.g. `developer`, `infra`, `data`). `developer` is on by default; other packs are off until the user enables them.

You can also put your own packs in `~/Library/Application Support/Koe/packs/` without contributing them.
