#!/usr/bin/env python3
"""文字起こし方式の公平な比較（ブラインド判定用）。

正解を 1 つの方式の出力から作ると、その方式に有利になる。そこで同じ録音を複数の方式で
文字起こしし、どれがどの方式かを伏せた状態で並べる。判定者（人か LLM）はセッションの文脈も見て
「本当は何と言ったか」を reference に書き、最後に score で方式ごとの CER を出す。

  koe_bench.py build --session <セッション ID の先頭> [--limit 40] -o bench.json
  koe_bench.py show bench.json            # 判定用に、伏せた出力と文脈を並べる
  koe_bench.py score bench.json           # reference を入れた後、方式ごとの CER

方式:
  A turbo + 用語辞書入りプロンプト（今の Koe と同じ）
  B large-v3 + 同じプロンプト
  C turbo + プロンプト + 直前の発話（同じアプリ・3 分以内）を文脈として渡す
  D turbo、プロンプトなし
"""

import argparse
import json
import random
import sys
from datetime import timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import koe_eval as ke  # noqa: E402

KOE = ke.HISTORY.parent
BASE_PROMPT = "これで合ってる？はい、承知しました。それって本当？では、次の作業に進みましょう。"


def glossary_prompt():
    path = KOE / "glossary.txt"
    terms = [l.strip() for l in path.read_text().splitlines() if l.strip() and not l.startswith("#")] if path.exists() else []
    out, n = [], 0
    for t in terms:
        if n + len(t) > 120:
            break
        out.append(t)
        n += len(t) + 1
    return ("、".join(out) + "。" if out else "") + BASE_PROMPT


def build(a):
    recs = {r["id"]: r for r in ke.load_records()}
    ordered = sorted(recs.values(), key=lambda r: r["id"])
    events = ke._load_session_events(min(ke._record_time(r) for r in ordered) - timedelta(days=1))
    picked = []
    for r in ordered:
        if not r.get("raw") or r.get("dropped") or (r.get("voiced_seconds") or 0) < 2 or not r["_wav"].exists():
            continue
        c = ke.find_context(r, events)
        if c and c["session"].startswith(a.session):
            picked.append((r, c))
    picked = picked[-a.limit:]
    gp = glossary_prompt()

    def prev_text(r):
        i = ordered.index(r)
        for p in reversed(ordered[:i]):
            if ke._record_time(r) - ke._record_time(p) > timedelta(minutes=3):
                return ""
            if p.get("app") == r.get("app") and p.get("pasted"):
                return p["pasted"]
        return ""

    outputs = {r["id"]: {} for r, _ in picked}
    for model, configs in (
        ("ggml-large-v3-turbo.bin", {"A": lambda r: gp, "C": lambda r: (prev_text(r)[-150:] + " " + gp).strip(), "D": lambda r: ""}),
        ("ggml-large-v3.bin", {"B": lambda r: gp}),
    ):
        server = ke.start_server(ke.WHISPER_HOME / "models" / model, None)
        try:
            for r, _ in picked:
                for key, prompt_of in configs.items():
                    outputs[r["id"]][key] = ke.transcribe(r["_wav"], prompt=prompt_of(r))
        finally:
            server.terminate()
        print(f"{model}: done", file=sys.stderr)

    rng = random.Random(0)
    items = []
    for r, c in picked:
        keys = list(outputs[r["id"]])
        rng.shuffle(keys)
        items.append({
            "id": r["id"],
            "blind": {f"#{i + 1}": outputs[r["id"]][k] for i, k in enumerate(keys)},
            "key": {f"#{i + 1}": k for i, k in enumerate(keys)},
            "context": {"reply": c["reply"][:300], "next": c["next"][:200]},
            "reference": None,
        })
    Path(a.out).write_text(json.dumps({"glossary_prompt": gp, "items": items}, ensure_ascii=False, indent=1))
    print(f"{len(items)} items -> {a.out}")


def build_mics(a):
    """同じ発話を、主のマイクともう 1 本のマイクの録音で文字起こしし、どちらかを伏せて並べる"""
    recs = [r for r in ke.load_records() if r.get("alt_audio") and r.get("raw") and not r.get("dropped")]
    recs = recs[-a.limit:]
    gp = glossary_prompt()
    server = ke.start_server(ke.WHISPER_HOME / "models" / "ggml-large-v3-turbo.bin", None)
    items = []
    rng = random.Random(0)
    try:
        for r in recs:
            alt = r["_wav"].with_name(r["alt_audio"])
            if not alt.exists():
                continue
            outs = {"main:" + (r.get("device") or "-"): ke.transcribe(r["_wav"], prompt=gp),
                    "alt:" + (r.get("alt_device") or "-"): ke.transcribe(alt, prompt=gp)}
            keys = list(outs)
            rng.shuffle(keys)
            items.append({"id": r["id"], "blind": {f"#{i + 1}": outs[k] for i, k in enumerate(keys)},
                          "key": {f"#{i + 1}": k for i, k in enumerate(keys)},
                          "context": {"reply": "", "next": ""}, "reference": None})
    finally:
        server.terminate()
    Path(a.out).write_text(json.dumps({"glossary_prompt": gp, "items": items}, ensure_ascii=False, indent=1))
    print(f"{len(items)} items -> {a.out}")


def _parse_glossary(path):
    out = []
    if not Path(path).exists():
        return out
    for l in Path(path).read_text().splitlines():
        l = l.strip()
        if not l or l.startswith("#"):
            continue
        t, *al = l.split("\t", 1)
        out.append((t.strip(), [x.strip() for x in (al[0].replace("/", "／").split("／") if al else []) if x.strip()]))
    return out


def _autocorrect(text, entries):
    import re
    pairs = sorted(((a, t) for t, al in entries for a in al if not a.startswith("~") and len(a) >= 2 and a != t), key=lambda x: -len(x[0]))
    for wrong, right in pairs:
        base, _, follow = wrong.partition(">")
        text = re.sub(r"(?<![\u30A0-\u30FFA-Za-z0-9])" + re.escape(base) + r"(?![\u30A0-\u30FFA-Za-z0-9])" + (f"(?={follow})" if follow else ""), right, text)
    return text


def build_packs(a):
    """同じ録音を「用語パックなし」「用語パックあり（プロンプトの語＋自動置き換え）」で文字起こしし、伏せて並べる"""
    pack_files = [Path(__file__).resolve().parent.parent / "packs" / f"{p}.txt" for p in a.packs.split(",")]
    pack = [e for f in pack_files for e in _parse_glossary(f)]
    personal = _parse_glossary(KOE / "glossary.txt")
    recent = [(r.get("pasted") or "").lower() for r in ke.load_records()[-300:]]

    def prompt_with(entries):
        def hits(t, al):
            keys = [k.lstrip("~").lower() for k in [t] + al if len(k.lstrip("~")) >= 2]
            return sum(1 for x in recent if any(k in x for k in keys))
        # アプリと同じ: 最近出てきた語が先。出てこなかった語は渡された順（個人の辞書が先）
        ranked = sorted(entries, key=lambda e: -hits(*e))
        out, n = [], 0
        for t, _ in ranked:
            if t in out or n + len(t) > 120:
                continue
            out.append(t)
            n += len(t) + 1
        return ("、".join(out) + "。" if out else "") + BASE_PROMPT

    p0, p1 = prompt_with(personal), prompt_with(personal + pack)
    recs = [r for r in ke.load_records() if r.get("raw") and not r.get("dropped") and (r.get("voiced_seconds") or 0) >= 2 and r["_wav"].exists()]
    recs = recs[-a.limit:]
    server = ke.start_server(ke.WHISPER_HOME / "models" / "ggml-large-v3-turbo.bin", None)
    items, rng = [], random.Random(0)
    try:
        for r in recs:
            outs = {"nopack": _autocorrect(ke.transcribe(r["_wav"], prompt=p0), personal),
                    "pack": _autocorrect(ke.transcribe(r["_wav"], prompt=p1), personal + pack)}
            keys = list(outs)
            rng.shuffle(keys)
            items.append({"id": r["id"], "blind": {f"#{i + 1}": outs[k] for i, k in enumerate(keys)},
                          "key": {f"#{i + 1}": k for i, k in enumerate(keys)},
                          "context": {"reply": "", "next": ""}, "reference": None})
    finally:
        server.terminate()
    Path(a.out).write_text(json.dumps({"prompt_nopack": p0, "prompt_pack": p1, "items": items}, ensure_ascii=False, indent=1))
    same = sum(1 for it in items if len(set(it["blind"].values())) == 1)
    print(f"{len(items)} items -> {a.out}（両方同じ出力: {same} 件。違いが出たものだけ判定すればよい）")


def build_silver(a):
    """自分の声の試験セット（koe_corpus.py）に準正解を付ける。
    会議ツールの文字起こし・whisper turbo・large-v3 を伏せて並べ、LLM（既定は claude -p）に「本当は何と言ったか」を判定させる。
    一度作れば、設定を変えるたびに使い回せる"""
    import subprocess
    corpus = KOE / "corpus"
    sets = [d for d in sorted(corpus.iterdir()) if (d / "items.json").exists() and (not a.only or d.name in a.only.split(","))]
    gp = glossary_prompt()
    for d in sets:
        meta = json.loads((d / "items.json").read_text())
        todo = [it for it in meta["items"] if (a.redo and not it.get("unaligned")) or not it.get("reference")]
        if not todo:
            continue
        outs = {}
        for model in ("ggml-large-v3-turbo.bin", "ggml-large-v3.bin"):
            server = ke.start_server(ke.WHISPER_HOME / "models" / model, None)
            try:
                for it in todo:
                    outs.setdefault(it["id"], {})[model] = ke.transcribe(d / (it["id"].split("/")[1] + ".wav"), prompt=gp)
            finally:
                server.terminate()
        rng = random.Random(0)
        for k in range(0, len(todo), a.batch):
            chunk = todo[k:k + a.batch]
            blocks = []
            for n, it in enumerate(chunk):
                cands = [outs[it["id"]]["ggml-large-v3-turbo.bin"], outs[it["id"]]["ggml-large-v3.bin"]]
                rng.shuffle(cands)
                blocks.append(f"[{n}]\n" + "\n".join(f"  候補{j + 1}: {c}" for j, c in enumerate(cands))
                              + f"\n  会議ツールの文字起こし（前後に余分な部分を含むことがある。表記の参考）: {it['vtt_text']}")
            prompt = ("次は同じ音声区間を 2 つの音声認識で書き起こした候補と、会議ツールの文字起こしです。"
                      "候補 1・2 はこの区間の音声そのものの書き起こし。会議ツールの文字起こしは区間の前後を含むことがあるので、"
                      "区間に入っていない部分は足さず、語の表記の参考にだけ使う。"
                      "話し手がこの区間で本当に言ったことを推定して、書き起こしとして 1 つにまとめてください。"
                      "言いよどみ・言い直しも言った通りに残す（整えない）。固有名詞・技術用語は正しい表記にする。"
                      "JSON の配列だけを返す（番号順）: [\"発話0\", \"発話1\", ...]\n\n" + "\n\n".join(blocks))
            res = subprocess.run(a.judge.split(), input=prompt, capture_output=True, text=True, timeout=600, cwd="/tmp").stdout
            try:
                refs = json.loads(res[res.index("["):res.rindex("]") + 1])
            except ValueError:
                print(f"  {d.name} {k}: 応答を読めませんでした", file=sys.stderr)
                continue
            for it, ref in zip(chunk, refs):
                it["reference"] = ref
                it["whisper_turbo"] = outs[it["id"]]["ggml-large-v3-turbo.bin"]
            (d / "items.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
        print(f"{d.name}: 準正解 {sum(1 for i in meta['items'] if i.get('reference'))}/{len(meta['items'])}", flush=True)


def score_corpus(a):
    """自分の声の試験セットで、今の設定（turbo＋用語辞書のプロンプト）の誤り率を出す"""
    corpus = KOE / "corpus"
    gp = glossary_prompt() if not a.prompt else a.prompt
    server = ke.start_server(ke.WHISPER_HOME / "models" / "ggml-large-v3-turbo.bin", None)
    allc = []
    try:
        for d in sorted(corpus.iterdir()):
            if not (d / "items.json").exists():
                continue
            items = [it for it in json.loads((d / "items.json").read_text())["items"] if it.get("reference") and not it.get("unaligned")]
            c = [ke.cer(ke.transcribe(d / (it["id"].split("/")[1] + ".wav"), prompt=gp), it["reference"]) for it in items]
            if c:
                print(f"  {d.name:<20} CER {sum(c) / len(c):6.1%} (n={len(c)})")
                allc += c
    finally:
        server.terminate()
    if allc:
        print(f"  全体                 CER {sum(allc) / len(allc):6.1%} (n={len(allc)})")


def compare_corpus(a):
    """自分の声の試験セットで、用語パックなし／あり（プロンプトの語＋自動置き換え）を比べる"""
    from statistics import mean, median
    packs_dir = Path(__file__).resolve().parent.parent / "packs"
    user_packs = KOE / "packs"
    pack = []
    for name in a.packs.split(","):
        for d in (packs_dir, user_packs):
            if (d / f"{name}.txt").exists():
                pack += _parse_glossary(d / f"{name}.txt")
                break
    personal = _parse_glossary(KOE / "glossary.txt")
    recent = [(r.get("pasted") or "").lower() for r in ke.load_records()[-300:]]

    def prompt_with(entries):
        def hits(t, al):
            keys = [k.lstrip("~").lower() for k in [t] + al if len(k.lstrip("~")) >= 2]
            return sum(1 for x in recent if any(k in x for k in keys))
        out, n = [], 0
        for t, _ in sorted(entries, key=lambda e: -hits(*e)):
            if t in out or n + len(t) > 120:
                continue
            out.append(t)
            n += len(t) + 1
        return ("、".join(out) + "。" if out else "") + BASE_PROMPT

    p0, p1 = prompt_with(personal), prompt_with(personal + pack)
    server = ke.start_server(ke.WHISPER_HOME / "models" / "ggml-large-v3-turbo.bin", None)
    res = {}
    changed = []
    try:
        for d in sorted((KOE / "corpus").iterdir()):
            if not (d / "items.json").exists():
                continue
            group = d.name.split("-")[0]
            for it in json.loads((d / "items.json").read_text())["items"]:
                if not it.get("reference") or it.get("unaligned"):
                    continue
                wav = d / (it["id"].split("/")[1] + ".wav")
                h0 = _autocorrect(ke.transcribe(wav, prompt=p0), personal)
                h1 = _autocorrect(ke.transcribe(wav, prompt=p1), personal + pack)
                c0, c1 = ke.cer(h0, it["reference"]), ke.cer(h1, it["reference"])
                res.setdefault(group, []).append((c0, c1))
                if abs(c0 - c1) >= 0.05:
                    changed.append({"id": it["id"], "nopack": h0, "pack": h1, "reference": it["reference"], "d": round(c1 - c0, 3)})
    finally:
        server.terminate()
    print(f"用語パック: {a.packs}")
    for g, rows in res.items():
        c0 = [x for x, _ in rows]; c1 = [y for _, y in rows]
        better = sum(1 for x, y in rows if y < x - 1e-9); worse = sum(1 for x, y in rows if y > x + 1e-9)
        print(f"  {g:<8} n={len(rows):<4} パックなし 平均 {mean(c0):.1%} 中央値 {median(c0):.1%} / パックあり 平均 {mean(c1):.1%} 中央値 {median(c1):.1%}"
              f"  良くなった {better} / 悪くなった {worse} / 同じ {len(rows) - better - worse}")
    out = KOE / "evals" / "compare-packs.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"prompt_nopack": p0, "prompt_pack": p1, "changed": changed}, ensure_ascii=False, indent=1))
    print(f"  差が 5% 以上の区間: {len(changed)} 件 -> {out}")


def compare_terms(a):
    """用語が出てくる区間だけで、準正解にある用語が出力にも正しい表記で出ているか（用語の正解率）を比べる。
    全区間の平均 CER では、用語は数 % の区間・数文字なので効き目が埋もれる"""
    packs_dir = Path(__file__).resolve().parent.parent / "packs"
    def load(name):
        for d in (packs_dir, KOE / "packs"):
            if (d / f"{name}.txt").exists():
                return _parse_glossary(d / f"{name}.txt")
        return []
    personal = _parse_glossary(KOE / "glossary.txt")
    org = _parse_glossary(KOE / "org_glossary.txt")
    # 公式のパック（developer）と、自分で入れたパック（~/Library/Application Support/Koe/packs/*.txt）
    user_packs = [e for f in sorted((KOE / "packs").glob("*.txt")) if f.stem != "developer" for e in _parse_glossary(f)]
    layers = {"developer": load("developer"), "user": user_packs, "org": org}
    terms = {t for es in layers.values() for t, _ in es if len(t) >= 2}
    recent = [(r.get("pasted") or "").lower() for r in ke.load_records()[-300:]]

    def prompt_with(entries):
        def hits(t, al):
            keys = [k.lstrip("~").lower() for k in [t] + al if len(k.lstrip("~")) >= 2]
            return sum(1 for x in recent if any(k in x for k in keys))
        out, n = [], 0
        for t, _ in sorted(entries, key=lambda e: -hits(*e)):
            if t in out or n + len(t) > 120:
                continue
            out.append(t)
            n += len(t) + 1
        return ("、".join(out) + "。" if out else "") + BASE_PROMPT

    configs = {
        "なし（個人の辞書だけ）": (personal, personal),
        "開発者向け": (personal + layers["developer"], personal + layers["developer"]),
        "自分で入れたパック": (personal + layers["user"], personal + layers["user"]),
        "全部（実際の Koe と同じ）": (personal + layers["developer"] + layers["user"] + org, personal + layers["developer"] + layers["user"]),
    }
    clips = []
    for d in sorted((KOE / "corpus").iterdir()):
        if not (d / "items.json").exists():
            continue
        for it in json.loads((d / "items.json").read_text())["items"]:
            ref = it.get("reference")
            if not ref or it.get("unaligned"):
                continue
            found = [t for t in terms if t.lower() in ref.lower()]
            if found:
                clips.append((d / (it["id"].split("/")[1] + ".wav"), ref, found))
    print(f"用語が出てくる区間: {len(clips)}（用語の出現 {sum(len(f) for _, _, f in clips)} 回）")
    server = ke.start_server(ke.WHISPER_HOME / "models" / "ggml-large-v3-turbo.bin", None)
    detail = {}
    try:
        for name, (pentries, aentries) in configs.items():
            prompt = prompt_with(pentries)
            ok = total = 0
            misses = []
            for wav, ref, found in clips:
                out = _autocorrect(ke.transcribe(wav, prompt=prompt), aentries)
                for t in found:
                    total += 1
                    if t.lower() in out.lower():
                        ok += 1
                    else:
                        misses.append(t)
            detail[name] = misses
            print(f"  {name:<22} 用語の正解率 {ok / total:.0%}（{ok}/{total}）", flush=True)
    finally:
        server.terminate()
    from collections import Counter
    for name, m in detail.items():
        print(f"  {name} で外した語: " + "、".join(f"{k}({v})" for k, v in Counter(m).most_common(10)))


def show(a):
    d = json.loads(Path(a.file).read_text())
    for it in d["items"]:
        print(f"== {it['id']}")
        for k, v in it["blind"].items():
            print(f"  {k}: {v}")
        print(f"  [Claude の返答] {it['context']['reply'][:200]}")
        print(f"  [次の発話] {it['context']['next'][:150]}")


def score(a):
    d = json.loads(Path(a.file).read_text())
    from collections import defaultdict
    per = defaultdict(list)
    for it in d["items"]:
        if not it.get("reference"):
            continue
        for label, text in it["blind"].items():
            per[it["key"][label]].append(ke.cer(text, it["reference"]))
    names = {"nopack": "用語パックなし", "pack": "用語パックあり", "A": "turbo + プロンプト（今）", "B": "large-v3 + プロンプト", "C": "turbo + プロンプト + 直前の発話", "D": "turbo、プロンプトなし"}
    for k in sorted(per):
        v = per[k]
        print(f"  {k} {names.get(k, k):<28} CER {sum(v) / len(v):6.1%}  (n={len(v)})")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("build")
    s.add_argument("--session", required=True)
    s.add_argument("--limit", type=int, default=40)
    s.add_argument("-o", "--out", required=True)
    s.set_defaults(func=build)
    s = sub.add_parser("build-mics")
    s.add_argument("--limit", type=int, default=40)
    s.add_argument("-o", "--out", required=True)
    s.set_defaults(func=build_mics)
    s = sub.add_parser("build-packs")
    s.add_argument("--packs", default="developer")
    s.add_argument("--limit", type=int, default=60)
    s.add_argument("-o", "--out", required=True)
    s.set_defaults(func=build_packs)
    s = sub.add_parser("build-silver")
    s.add_argument("--only", help="対象の試験セット名（カンマ区切り）")
    s.add_argument("--batch", type=int, default=15)
    s.add_argument("--judge", default="claude -p --model sonnet")
    s.add_argument("--redo", action="store_true", help="準正解があっても作り直す（区間を切り直したとき）")
    s.set_defaults(func=build_silver)
    s = sub.add_parser("score-corpus")
    s.add_argument("--prompt")
    s.set_defaults(func=score_corpus)
    s = sub.add_parser("compare-corpus")
    s.add_argument("--packs", default="developer")
    s.set_defaults(func=compare_corpus)
    s = sub.add_parser("compare-terms")
    s.set_defaults(func=compare_terms)
    s = sub.add_parser("show")
    s.add_argument("file")
    s.set_defaults(func=show)
    s = sub.add_parser("score")
    s.add_argument("file")
    s.set_defaults(func=score)
    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
