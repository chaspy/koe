#!/usr/bin/env python3
"""自分の声の試験セットを、会議やポッドキャストの録音から作る。

Teams などの録音（mp4 / m4a）と、話者名つきの文字起こし（VTT）から、指定した話者の発言区間を切り出す。
話さなくても、本人の声・話し方で設定を比べられるようにするための材料。

  koe_corpus.py add --media rec.mp4 --vtt rec.vtt --speaker "山田 太郎" --name podcast-0409
  koe_corpus.py add-auto --media rec.mp4 --name mtg-example [--sample 40]   # 話者名の文字起こしが無いとき
  koe_corpus.py list

出力: ~/Library/Application Support/Koe/corpus/<name>/<n>.wav と items.json
  items.json の各要素: {"id", "start", "end", "vtt_text"}  vtt_text は会議ツールの文字起こし（正解ではない）
正解（準正解）は koe_bench.py build-silver で、複数の文字起こしを伏せて判定して作る。
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import koe_eval as ke  # noqa: E402

CORPUS = ke.HISTORY.parent / "corpus"


def ts(s):
    h, m, rest = s.split(":")
    return int(h) * 3600 + int(m) * 60 + float(rest)


def parse_vtt(path):
    cues, cur = [], None
    for line in Path(path).read_text(encoding="utf-8", errors="ignore").splitlines():
        m = re.match(r"^(\d+:\d+:\d+\.\d+)\s+-->\s+(\d+:\d+:\d+\.\d+)", line)
        if m:
            cur = {"start": ts(m.group(1)), "end": ts(m.group(2)), "speaker": None, "text": ""}
            cues.append(cur)
            continue
        if cur is None or not line.strip():
            continue
        if re.match(r"^[0-9a-f]{8}-[0-9a-f-]{27}/\d+-\d+$", line.strip()) or re.match(r"^\d+$", line.strip()):
            continue  # 次の区間の ID 行
        v = re.match(r"^<v ([^>]+)>(.*?)(</v>)?$", line.strip())
        if v:
            cur["speaker"] = v.group(1).strip()
            cur["text"] += v.group(2).strip()
        else:
            cur["text"] += line.strip()
    return [c for c in cues if c["speaker"]]


def merge(cues, speaker, gap=1.0, max_len=20.0, min_len=2.0):
    """同じ話者の連続した区間をつなぎ、発話らしい長さ（2〜20 秒）にする"""
    out = []
    for c in cues:
        if c["speaker"] != speaker:
            continue
        if out and c["start"] - out[-1]["end"] <= gap and c["end"] - out[-1]["start"] <= max_len:
            out[-1]["end"] = c["end"]
            out[-1]["vtt_text"] += c["text"]
        else:
            out.append({"start": c["start"], "end": c["end"], "vtt_text": c["text"]})
    return [o for o in out if o["end"] - o["start"] >= min_len]


def cmd_add(a):
    cues = parse_vtt(a.vtt)
    speakers = sorted({c["speaker"] for c in cues})
    if a.speaker not in speakers:
        sys.exit(f"話者 {a.speaker!r} が VTT にありません: {speakers}")
    segs = merge(cues, a.speaker)
    d = CORPUS / a.name
    d.mkdir(parents=True, exist_ok=True)
    items = []
    for n, s in enumerate(segs):
        wav = d / f"{n:04d}.wav"
        # 前後を少しだけ広げる（VTT の区間は語頭・語尾が詰まりがち）
        start, end = max(0, s["start"] - 0.2), s["end"] + 0.3
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", f"{start:.2f}", "-to", f"{end:.2f}", "-i", a.media,
                        "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav)], check=True)
        items.append({"id": f"{a.name}/{n:04d}", "start": round(start, 2), "end": round(end, 2), "vtt_text": s["vtt_text"]})
    (d / "items.json").write_text(json.dumps({"media": str(a.media), "speaker": a.speaker, "items": items}, ensure_ascii=False, indent=1))
    total = sum(i["end"] - i["start"] for i in items)
    print(f"{a.name}: {len(items)} 区間（計 {total / 60:.1f} 分）-> {d}")


def cmd_add_auto(a):
    """話者名つきの文字起こしが無い録音から、whisper の区切りで発言区間を切り出す（話者は区別しない）"""
    import random
    import tempfile
    d = CORPUS / a.name
    if (d / "items.json").exists() and not a.force:
        print(f"{a.name}: 作成済み（作り直すなら --force）")
        return
    d.mkdir(parents=True, exist_ok=True)
    tmp = Path(tempfile.mkdtemp())
    full = tmp / "full.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", a.media, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(full)], check=True)
    cli = ke.WHISPER_HOME / "build/bin/whisper-cli"
    model = ke.WHISPER_HOME / "models/ggml-large-v3-turbo.bin"
    subprocess.run([str(cli), "-m", str(model), "-l", "ja", "-oj", "-of", str(tmp / "full"), "-np", str(full)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    segs = json.loads((tmp / "full.json").read_text(errors="ignore"))["transcription"]
    def sec(t):
        h, m, rest = t.replace(",", ".").split(":")
        return int(h) * 3600 + int(m) * 60 + float(rest)
    merged = []
    for sgm in segs:
        st, en, tx = sec(sgm["timestamps"]["from"]), sec(sgm["timestamps"]["to"]), sgm["text"].strip()
        if not tx:
            continue
        if merged and st - merged[-1]["end"] <= 0.6 and en - merged[-1]["start"] <= 20:
            merged[-1]["end"] = en
            merged[-1]["vtt_text"] += tx
        else:
            merged.append({"start": st, "end": en, "vtt_text": tx})
    merged = [m for m in merged if 2.0 <= m["end"] - m["start"] <= 20 and m["vtt_text"] not in ("ご視聴ありがとうございました",)]
    random.Random(0).shuffle(merged)
    picked = sorted(merged[:a.sample], key=lambda m: m["start"])
    items = []
    for n, s in enumerate(picked):
        wav = d / f"{n:04d}.wav"
        start, end = max(0, s["start"] - 0.2), s["end"] + 0.3
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", f"{start:.2f}", "-to", f"{end:.2f}", "-i", str(full),
                        "-c:a", "pcm_s16le", str(wav)], check=True)
        # vtt_text の代わりに、録音全体を通した文字起こし（区間単体より文脈がある）を候補として残す
        items.append({"id": f"{a.name}/{n:04d}", "start": round(start, 2), "end": round(end, 2), "vtt_text": s["vtt_text"]})
    (d / "items.json").write_text(json.dumps({"media": str(a.media), "speaker": None, "items": items}, ensure_ascii=False, indent=1))
    print(f"{a.name}: {len(items)} 区間（候補 {len(merged)} から抽出）-> {d}")


def _whisper_segments(media):
    """録音全体を whisper で文字起こしし、区切り（開始・終了・テキスト）を返す"""
    import tempfile
    tmp = Path(tempfile.mkdtemp())
    full = tmp / "full.wav"
    subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", media, "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(full)], check=True)
    cli = ke.WHISPER_HOME / "build/bin/whisper-cli"
    model = ke.WHISPER_HOME / "models/ggml-large-v3-turbo.bin"
    subprocess.run([str(cli), "-m", str(model), "-l", "ja", "-oj", "-of", str(tmp / "full"), "-np", str(full)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    def sec(t):
        h, m, rest = t.replace(",", ".").split(":")
        return int(h) * 3600 + int(m) * 60 + float(rest)
    segs = [{"start": sec(x["timestamps"]["from"]), "end": sec(x["timestamps"]["to"]), "text": x["text"].strip()}
            for x in json.loads((tmp / "full.json").read_text(errors="ignore"))["transcription"] if x["text"].strip()]
    return full, segs


def cmd_realign(a):
    """VTT の時刻で切った区間を、whisper の区切りに合わせて切り直す（話者は VTT、範囲は whisper）。準正解はそのまま使う"""
    import difflib
    d = CORPUS / a.name
    meta = json.loads((d / "items.json").read_text())
    full, segs = _whisper_segments(meta["media"])
    moved = 0
    for it in meta["items"]:
        target = ke.normalize(it.get("reference") or it["vtt_text"])
        near = [s for s in segs if s["end"] >= it["start"] - 2.0 and s["start"] <= it["end"] + 2.0]
        best, best_score = None, 0.0
        # 近くの whisper の区切りを連続でつないだもののうち、文面が一番近い範囲を選ぶ
        for i in range(len(near)):
            for j in range(i, min(i + 4, len(near))):
                txt = ke.normalize("".join(s["text"] for s in near[i:j + 1]))
                sc = difflib.SequenceMatcher(None, txt, target).ratio()
                if sc > best_score:
                    best, best_score = (near[i]["start"], near[j]["end"]), sc
        if best and best_score >= 0.5:
            it["start"], it["end"], it["align_score"] = round(max(0, best[0] - 0.1), 2), round(best[1] + 0.2, 2), round(best_score, 2)
            moved += 1
        else:
            it["align_score"] = round(best_score, 2)
            it["unaligned"] = True  # 合う区切りが無い（相手の声と重なっている等）。採点から外す
        wav = d / (it["id"].split("/")[1] + ".wav")
        subprocess.run(["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-ss", f"{it['start']:.2f}", "-to", f"{it['end']:.2f}",
                        "-i", str(full), "-c:a", "pcm_s16le", str(wav)], check=True)
        it.pop("whisper_turbo", None)  # 範囲が変わったので古い出力は使わない
    (d / "items.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1))
    print(f"{a.name}: {moved}/{len(meta['items'])} 区間を whisper の区切りに合わせた（合わない区間は採点から外す）")


def cmd_list(a):
    for d in sorted(CORPUS.glob("*/items.json")):
        x = json.loads(d.read_text())
        n = len(x["items"]); silver = sum(1 for i in x["items"] if i.get("reference"))
        print(f"  {d.parent.name:<24} {n:>4} 区間  準正解 {silver}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("add")
    s.add_argument("--media", required=True)
    s.add_argument("--vtt", required=True)
    s.add_argument("--speaker", required=True)
    s.add_argument("--name", required=True)
    s.set_defaults(func=cmd_add)
    s = sub.add_parser("add-auto")
    s.add_argument("--media", required=True)
    s.add_argument("--name", required=True)
    s.add_argument("--sample", type=int, default=40)
    s.add_argument("--force", action="store_true")
    s.set_defaults(func=cmd_add_auto)
    s = sub.add_parser("realign")
    s.add_argument("--name", required=True)
    s.set_defaults(func=cmd_realign)
    s = sub.add_parser("list")
    s.set_defaults(func=cmd_list)
    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
