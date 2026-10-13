#!/usr/bin/env python3
"""使い続けるだけで Koe の用語辞書を育てる（すべてローカルで完結）。

履歴の文字起こしをローカルの Ollama に読ませて「誤変換らしき語 → 正しい表記」を抜き出し、
複数回出てきた正しい表記を用語辞書に足す。辞書は Koe が whisper の初期プロンプトと
LLM 整形に使うので、次の発話から効く。

  koe_improve.py            # 未処理の履歴を処理して辞書を更新
  koe_improve.py --dry-run  # 辞書は書き換えず、候補だけ表示

辞書: ~/Library/Application Support/Koe/glossary.txt（1 行 1 語、# はコメント。消せば次から使われない）
候補: ~/Library/Application Support/Koe/glossary_candidates.json
発話の本文は標準出力に出さない（出すのは件数と辞書に入る語だけ）。
"""

import argparse
import re
import json
import os
import sys
import urllib.request
from pathlib import Path

KOE = Path(os.environ.get("KOE_HOME", Path.home() / "Library/Application Support/Koe"))
HISTORY = KOE / "history"
GLOSSARY = KOE / "glossary.txt"
CANDIDATES = KOE / "glossary_candidates.json"
OLLAMA = os.environ.get("KOE_OLLAMA", "http://localhost:11434")
MODEL = os.environ.get("KOE_IMPROVE_MODEL", "qwen2.5:32b")
MIN_COUNT = int(os.environ.get("KOE_GLOSSARY_MIN_COUNT", "2"))
MAX_TERMS = 40
# 辞書に入れるのは「語」だけ。文・句読点入り・長いものは捨てる
TERM_RE = re.compile(r"^[^\s、。，．,.？?！!「」]{2,15}$")
BATCH = 8

PROMPT = """以下は日本語の音声認識（whisper）の出力です。IT 企業の会話で、技術用語・英字略語・サービス名・固有名詞がよく出ます。
音が近いせいで誤って書き起こされたと**強く**思われる語だけを抜き出し、正しい表記を推定してください。

- wrong は入力に実際に含まれる文字列をそのまま書く。1 語だけ（文やフレーズは不可）
- right は正しい表記の 1 語（英字略語・製品名は公式の綴り）。2〜15 文字
- 普通の日本語の言い回しや、正しく書けている語は出さない
- 確信がなければ出さない。推測で埋めない
- 人名は出さない

JSON で {"fixes": [{"wrong": "...", "right": "..."}]} だけを返してください。該当がなければ {"fixes": []}。"""


def load_records():
    for j in sorted(HISTORY.glob("*/*.json")):
        try:
            yield j, json.loads(j.read_text())
        except json.JSONDecodeError:
            continue


def ask(texts):
    body = {
        "model": MODEL, "stream": False, "format": "json", "options": {"temperature": 0},
        "messages": [
            {"role": "system", "content": PROMPT},
            {"role": "user", "content": "\n".join(f"- {t}" for t in texts)},
        ],
    }
    req = urllib.request.Request(f"{OLLAMA}/api/chat", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    out = json.loads(urllib.request.urlopen(req, timeout=300).read())
    try:
        return json.loads(out["message"]["content"]).get("fixes", [])
    except (json.JSONDecodeError, AttributeError):
        return []


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    try:
        urllib.request.urlopen(f"{OLLAMA}/api/version", timeout=3)
    except Exception:
        sys.exit("Ollama が動いていません")

    cand = json.loads(CANDIDATES.read_text()) if CANDIDATES.exists() else {}
    todo = [(j, r) for j, r in load_records() if r.get("raw") and not r.get("glossary_scanned")]
    if not todo:
        print("未処理の履歴はありません")
        return

    found = 0
    for i in range(0, len(todo), BATCH):
        batch = todo[i:i + BATCH]
        texts = [r["raw"] for _, r in batch]
        joined = "\n".join(texts)
        for fx in ask(texts):
            wrong, right = (fx.get("wrong") or "").strip(), (fx.get("right") or "").strip()
            # 入力に実在しない wrong や、変化のないものは捨てる（LLM の創作よけ）
            if not wrong or wrong == right or wrong not in joined or not TERM_RE.match(right) or len(wrong) > 15:
                continue
            c = cand.setdefault(right, {"count": 0, "wrongs": []})
            c["count"] += 1
            if wrong not in c["wrongs"]:
                c["wrongs"].append(wrong)
            found += 1
        if not a.dry_run:
            for j, r in batch:
                r["glossary_scanned"] = True
                j.write_text(json.dumps(r, ensure_ascii=False, indent=2, sort_keys=True))

    ranked = sorted((k for k, v in cand.items() if v["count"] >= MIN_COUNT), key=lambda k: -cand[k]["count"])
    existing = []
    if GLOSSARY.exists():
        existing = [l.strip() for l in GLOSSARY.read_text().splitlines() if l.strip() and not l.startswith("#")]
    added = [t for t in ranked if t not in existing][: max(0, MAX_TERMS - len(existing))]

    print(f"処理した発話: {len(todo)} 件 / 誤変換候補: {found} 件 / 候補の語: {len(cand)} 語")
    print(f"辞書に追加: {', '.join(added) if added else 'なし'}")
    if a.dry_run:
        return

    CANDIDATES.write_text(json.dumps(cand, ensure_ascii=False, indent=2, sort_keys=True))
    if added:
        header = "" if GLOSSARY.exists() else "# Koe 用語辞書（1 行 1 語）。koe_improve.py が自動で足す。不要な語は消してよい\n"
        with GLOSSARY.open("a") as f:
            f.write(header + "".join(f"{t}\n" for t in added))


if __name__ == "__main__":
    main()
