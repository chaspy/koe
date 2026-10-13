#!/usr/bin/env python3
"""Koe の履歴を使って、文字起こし・LLM 整形の精度を比較評価する。

履歴: ~/Library/Application Support/Koe/history/YYYY-MM-DD/<id>.{wav,json}
正解テキストは各 json の "reference" に入れる（set-ref か直接編集）。
"reference_draft" は AI が付けた正解案で、review で人が確定すると reference になる。

  koe_eval.py list [--unlabeled] [--limit N]
  koe_eval.py pending                     # 正解も下書きもない発話を JSON で出す
  koe_eval.py unscanned                   # 用語辞書の更新にまだ使っていない発話を JSON で出す
  koe_eval.py mark-scanned <id>... | --all  # 用語辞書の更新に使った印を付ける
  koe_eval.py misses [--days N]           # 貼られなかった押下（取りこぼし）を理由別に数える
  koe_eval.py context [<id>...]           # Claude Code のセッション記録から、送信文・返答・次の発話を引く
  koe_eval.py set-comm <id> understood|corrected|unclear [--note "..."]
                                          # Claude に意図が通じたか（伝達）を記録する
  koe_eval.py comm [--days N]             # 伝達成功率（訂正が要った割合）を出す
  koe_eval.py trend [--days N]            # ①貼り付け ②伝達 の日次推移
  koe_eval.py packs [--days N]            # 用語パックの効き目（自動置き換えの件数・中身、パックあり/なしの伝達成功率）
  koe_eval.py quality [--days N]          # 音質の指標を、伝わった/伝わらなかった・マイク別に比べる
  koe_eval.py set-draft <id> "<正解案>"
  koe_eval.py review                      # 下書きを1件ずつ確定・修正する
  koe_eval.py set-ref <id> "<正解テキスト>"
  koe_eval.py score [--drafts]            # 保存済みの結果（その時の設定）を採点
  koe_eval.py run --tag turbo-p2 [--drafts] [--model PATH] [--prompt TEXT]
                  [--llm-model M] [--llm-endpoint URL] [--llm-prompt-file F]

--drafts を付けると、未確定の下書きも正解として扱う（暫定値）。

指標は CER（文字誤り率 = 編集距離 / 正解の文字数）。句読点・空白は除いて比較する。
外部ライブラリ不要。
"""

import argparse
import difflib
from datetime import datetime, timedelta, timezone
import json
import os
import subprocess
import sys
import time
import unicodedata
import urllib.request
import uuid
from pathlib import Path

HISTORY = Path(os.environ.get("KOE_HISTORY", Path.home() / "Library/Application Support/Koe/history"))
EVALS = HISTORY.parent / "evals"
WHISPER_HOME = Path(os.environ.get("WHISPER_CPP_HOME", Path.home() / ".local/src/whisper.cpp"))
DEFAULT_MODEL = WHISPER_HOME / "models/ggml-large-v3-turbo.bin"
EVAL_PORT = int(os.environ.get("KOE_EVAL_PORT", "18090"))  # 並行して回すときはずらす
CLAUDE_PROJECTS = Path(os.environ.get("CLAUDE_PROJECTS", Path.home() / ".claude/projects"))
DEFAULT_LLM_PROMPT = Path(__file__).resolve().parent.parent / "macos/Resources/cleanup_prompt.txt"

PUNCT = set("、。，．,.？?！!「」『』（）()・… 　\t\n\"'")


# ---------- records ----------

def load_records():
    recs = []
    for j in sorted(HISTORY.glob("*/*.json")):
        try:
            r = json.loads(j.read_text())
        except json.JSONDecodeError:
            continue
        r["_json"] = j
        r["_wav"] = j.with_suffix(".wav")
        recs.append(r)
    return recs


def find(rid):
    for r in load_records():
        if r.get("id") == rid:
            return r
    sys.exit(f"not found: {rid}")


def save(r):
    data = {k: v for k, v in r.items() if not k.startswith("_")}
    r["_json"].write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True))


# ---------- metric ----------

def normalize(s):
    s = unicodedata.normalize("NFKC", s or "")
    return "".join(c for c in s if c not in PUNCT and not c.isspace())


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def cer(hyp, ref):
    h, r = normalize(hyp), normalize(ref)
    if not r:
        return 0.0 if not h else 1.0
    return edit_distance(h, r) / len(r)


def summarize(rows, keys):
    for k in keys:
        vals = [row[k] for row in rows if row.get(k) is not None]
        if vals:
            print(f"  {k:<12} mean CER {sum(vals) / len(vals):6.1%}  (n={len(vals)})")


# ---------- whisper / llm ----------

def start_server(model, prompt):
    exe = WHISPER_HOME / "build/bin/whisper-server"
    args = [str(exe), "-m", str(model), "-l", "ja", "--host", "127.0.0.1",
            "--port", str(EVAL_PORT), "-t", "4"]
    if prompt:
        args += ["--prompt", prompt]
    # 例: KOE_EVAL_SERVER_ARGS="-bs 5" でビームサーチを試す
    args += os.environ.get("KOE_EVAL_SERVER_ARGS", "").split()
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(240):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{EVAL_PORT}/", timeout=1)
            return proc
        except Exception:
            if proc.poll() is not None:
                sys.exit("whisper-server exited during startup")
            time.sleep(0.5)
    proc.kill()
    sys.exit("whisper-server startup timed out")


def transcribe(wav, prompt=None):
    boundary = uuid.uuid4().hex
    parts = []
    fields = [("response_format", "text"), ("temperature", "0.0")]
    if prompt is not None:
        fields.append(("prompt", prompt))  # リクエストごとの初期プロンプト（空文字でプロンプトなし）
    for name, value in fields:
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
                 f"Content-Type: audio/wav\r\n\r\n".encode() + wav.read_bytes() + b"\r\n")
    parts.append(f"--{boundary}--\r\n".encode())
    req = urllib.request.Request(f"http://127.0.0.1:{EVAL_PORT}/inference", data=b"".join(parts),
                                 headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    text = urllib.request.urlopen(req, timeout=300).read().decode()
    return " ".join(line.strip() for line in text.splitlines() if line.strip())


def llm_clean(text, model, endpoint, system_prompt, api_key=None):
    body = {"model": model, "temperature": 0, "stream": False,
            "messages": [{"role": "system", "content": system_prompt}, {"role": "user", "content": f"<transcript>{text}</transcript>"}]}
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    req = urllib.request.Request(endpoint.rstrip("/") + "/chat/completions",
                                 data=json.dumps(body).encode(), headers=headers)
    out = json.loads(urllib.request.urlopen(req, timeout=120).read())
    content = out["choices"][0]["message"]["content"]
    if "</think>" in content:
        content = content.split("</think>", 1)[1]
    return content.strip()


# ---------- commands ----------

def cmd_list(a):
    recs = load_records()
    if a.unlabeled:
        recs = [r for r in recs if not r.get("reference")]
    for r in recs[-a.limit:]:
        mark = "✓" if r.get("reference") else " "
        shown = r.get("cleaned") or r.get("raw") or ""
        print(f"{mark} {r['id']}  {r.get('audio_seconds', '?'):>5}s  {shown}")
    print(f"\n{len(recs)} records ({sum(1 for r in load_records() if r.get('reference'))} labeled)")


def cmd_pending(a):
    out = [{"id": r["id"], "app": r.get("app"), "audio_seconds": r.get("audio_seconds"),
            "raw": r.get("raw"), "cleaned": r.get("cleaned")}
           for r in load_records()
           if r.get("raw") and not r.get("dropped") and not r.get("reference") and not r.get("reference_draft")]
    print(json.dumps(out, ensure_ascii=False, indent=1))


def cmd_unscanned(a):
    out = [{"id": r["id"], "app": r.get("app"), "raw": r.get("raw")}
           for r in load_records() if r.get("raw") and not r.get("dropped") and not r.get("glossary_scanned")]
    print(json.dumps(out, ensure_ascii=False, indent=1))


def cmd_mark_scanned(a):
    ids = set(a.ids)
    n = 0
    for r in load_records():
        if r.get("id") in ids or (a.all and r.get("raw") and not r.get("glossary_scanned")):
            r["glossary_scanned"] = True
            save(r)
            n += 1
    print(f"marked {n}")


# ---------- Claude Code session context ----------
#
# Koe で Claude Code に入力した発話は、セッション記録（~/.claude/projects/*/*.jsonl）に
# ユーザー発話として残る。送信文（手で直した跡）・直後の返答（Claude の解釈）・次の発話（訂正）は
# 「本当に言いたかったこと」の手がかりになる。

def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text")
    return ""


def _is_human(d):
    # Claude が作業中に送った発話は queue-operation(enqueue) として残る
    if d.get("type") == "queue-operation":
        return d.get("operation") == "enqueue" and isinstance(d.get("content"), str) and bool(d["content"].strip())
    c = d.get("message", {}).get("content")
    if isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
        return False
    text = _text_of(c).strip()
    # エージェント間メッセージ・通知・コマンド出力などは人の発話ではない
    if not text or text.startswith("<") or text.startswith("Another Claude session"):
        return False
    return d.get("type") == "user" and not d.get("isMeta")


def _human_text(d):
    return d["content"] if d.get("type") == "queue-operation" else _text_of(d["message"]["content"])


def _record_time(r):
    local = datetime.strptime(r["id"][:19], "%Y-%m-%dT%H-%M-%S").astimezone()
    return local.astimezone(timezone.utc)


def _load_session_events(since):
    events = []
    for f in CLAUDE_PROJECTS.glob("*/*.jsonl"):
        if datetime.fromtimestamp(f.stat().st_mtime, timezone.utc) < since:
            continue
        rows = []
        for line in f.open(errors="ignore"):
            try:
                d = json.loads(line)
            except json.JSONDecodeError:
                continue
            if d.get("type") not in ("user", "assistant", "queue-operation") or not d.get("timestamp"):
                continue
            rows.append(d)
        events.append((f, rows))
    return events


def find_context(r, events):
    t = _record_time(r)
    raw = normalize(r.get("pasted") or r.get("raw"))
    best = None
    for f, rows in events:
        for i, d in enumerate(rows):
            if not _is_human(d):
                continue
            ts = datetime.fromisoformat(d["timestamp"].replace("Z", "+00:00"))
            # 貼り付けは数秒以内に届く。窓を広げると、手で貼り直した発言を「届いた」と誤判定する
            if not (t - timedelta(seconds=5) <= ts <= t + timedelta(seconds=20)):
                continue
            sent = _human_text(d)
            score = difflib.SequenceMatcher(None, raw, normalize(sent)).ratio()
            if raw and raw in normalize(sent):
                score = max(score, 0.95)
            if score < 0.6 or (best and best["score"] >= score):
                continue
            # 返答は、次に入力欄から送るまでの Claude の発言を全部（作業中に送った発話＝キューはまたぐ）
            reply, nxt = [], None
            for d2 in rows[i + 1:]:
                if _is_human(d2):
                    if nxt is None:
                        nxt = _human_text(d2)
                    if d2.get("type") != "queue-operation":
                        break
                elif d2.get("type") == "assistant":
                    reply.append(_text_of(d2["message"]["content"]))
            best = {"score": round(score, 2), "session": f.stem, "sent": sent,
                    "reply": "\n".join(x for x in reply if x.strip())[:600], "next": (nxt or "")[:300]}
    return best


def cmd_context(a):
    recs = [r for r in load_records() if r.get("raw") and not r.get("dropped")]
    if a.ids:
        recs = [r for r in recs if r["id"] in set(a.ids)]
    elif a.unscanned:
        recs = [r for r in recs if not r.get("glossary_scanned")]
    if not recs:
        print("[]")
        return
    events = _load_session_events(min(_record_time(r) for r in recs) - timedelta(days=1))
    out = []
    for r in recs:
        c = find_context(r, events)
        out.append({"id": r["id"], "raw": r.get("raw"), "context": c})
    print(json.dumps(out, ensure_ascii=False, indent=1))


def cmd_misses(a):
    from collections import Counter
    path = HISTORY.parent / "events.jsonl"
    if not path.exists():
        sys.exit("events.jsonl がありません")
    since = datetime.now(timezone.utc) - timedelta(days=a.days)
    events = []
    for line in path.read_text().splitlines():
        try:
            e = json.loads(line)
            e["_t"] = datetime.fromisoformat(e["t"].replace("Z", "+00:00"))
        except (json.JSONDecodeError, KeyError, ValueError):
            continue
        if e["_t"] >= since:
            events.append(e)
    c = Counter(e["outcome"] for e in events)
    for k, v in c.most_common():
        print(f"  {k:<16} {v}")
    total = sum(v for k, v in c.items() if k not in ("mic_restarted", "too_short"))
    pasted = c.get("pasted", 0)
    if total:
        print(f"\n  貼り付け成功率 {pasted / total:.0%}（{pasted}/{total}、too_short と誤操作の取り消しは除く）")
    # 失敗のあと 30 秒以内に貼れていれば「言い直して復帰」とみなす
    fails = [e for e in events if e["outcome"] in ("no_voice", "mic_silent", "hallucination", "error", "cancelled")]
    lost = recovered = 0
    for f in fails:
        if any(e["outcome"] == "pasted" and timedelta(0) < e["_t"] - f["_t"] <= timedelta(seconds=30) for e in events):
            recovered += 1
        lost += f.get("est_lost_chars", 0)
    if fails:
        print(f"  失敗 {len(fails)} 件のうち 30 秒以内に言い直して復帰 {recovered} 件 / 推定ロス {lost} 文字（記録のある分のみ）")


COMM = ("understood", "corrected", "unclear")


def cmd_set_comm(a):
    r = find(a.id)
    r["communication"] = a.outcome
    if a.note:
        r["communication_note"] = a.note
    save(r)
    print(f"{a.id}: {a.outcome}")


def cmd_comm(a):
    since = (datetime.now() - timedelta(days=a.days)).strftime("%Y-%m-%dT%H-%M-%S")
    recs = [r for r in load_records() if r.get("communication") and r["id"] >= since]
    if not recs:
        sys.exit("伝達の判定が付いた発話がありません")
    from collections import Counter
    c = Counter(r["communication"] for r in recs)
    judged = c["understood"] + c["corrected"]
    for k in COMM:
        print(f"  {k:<11} {c[k]}")
    if judged:
        print(f"\n  伝達成功率 {c['understood'] / judged:.1%}（訂正が要った {c['corrected']}/{judged}、unclear は除く）")


def cmd_trend(a):
    """① 押したのに入力されなかった割合（Koe 内の失敗 + 貼ったのに届かなかった）と ② 伝達成功率を日ごとに出す"""
    from collections import Counter, defaultdict
    since = datetime.now(timezone.utc) - timedelta(days=a.days)
    day = defaultdict(Counter)
    path = HISTORY.parent / "events.jsonl"
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                e = json.loads(line)
                t = datetime.fromisoformat(e["t"].replace("Z", "+00:00"))
            except (json.JSONDecodeError, KeyError, ValueError):
                continue
            if t < since:
                continue
            d = t.astimezone().strftime("%m/%d")
            o = e["outcome"]
            if o == "pasted":
                pass  # 貼り付け件数は履歴から数える
            elif o in ("no_voice", "mic_silent", "hallucination", "error", "not_ready", "start_failed"):
                day[d]["koe_fail"] += 1
            elif o == "cancelled" and e.get("reason") != "mouse" and (e.get("hold_seconds") or 0) >= 1.0:
                day[d]["koe_fail"] += 1
            elif o == "missed_press":
                day[d]["key_lost"] += 1
    recs = [r for r in load_records() if _record_time(r) >= since]
    events = _load_session_events(since - timedelta(days=1)) if recs else []
    for r in recs:
        d = _record_time(r).astimezone().strftime("%m/%d")
        if r.get("pasted"):
            day[d]["pasted"] += 1
        if r.get("pasted") and r.get("app") == "com.googlecode.iterm2":
            day[d]["iterm"] += 1
            if not find_context(r, events):
                day[d]["not_delivered"] += 1
        if r.get("communication"):
            day[d][r["communication"]] += 1
    print("  日付   押下  入力された  ①失敗(Koe内/届かず/キー取りこぼし)  ①成功率   ②判定  訂正  ②伝達成功率")
    rows = []
    for d in sorted(day):
        v = day[d]
        presses = v["pasted"] + v["koe_fail"] + v["key_lost"]
        delivered = v["pasted"] - v["not_delivered"]
        fail = v["koe_fail"] + v["not_delivered"] + v["key_lost"]
        judged = v["understood"] + v["corrected"]
        s1 = delivered / presses if presses else None
        s2 = v["understood"] / judged if judged else None
        rows.append({"date": d, "presses": presses, "delivered": delivered, "koe_fail": v["koe_fail"],
                     "not_delivered": v["not_delivered"], "key_lost": v["key_lost"], "judged": judged,
                     "corrected": v["corrected"], "paste_success": s1, "comm_success": s2})
        print(f"  {d}  {presses:>4}  {delivered:>8}    {fail:>3} ({v['koe_fail']}/{v['not_delivered']}/{v['key_lost']})"
              f"                    {(f'{s1:.1%}' if s1 is not None else '-'):>6}   {judged:>4}  {v['corrected']:>4}   "
              f"{(f'{s2:.1%}' if s2 is not None else '-'):>6}")
    print("\n  ① 基準 95% 以上 / ② 基準 95% 以上。①の「届かず」は iTerm（com.googlecode.iterm2）に貼った発話が Claude Code のセッション記録に無かったもの（iTerm 以外のターミナルは数えない）")
    if a.json:
        print(json.dumps(rows, ensure_ascii=False))


def cmd_packs(a):
    from collections import Counter, defaultdict
    since = (datetime.now() - timedelta(days=a.days)).strftime("%Y-%m-%dT%H-%M-%S")
    recs = [r for r in load_records() if r["id"] >= since and r.get("raw") and not r.get("dropped")]
    day = defaultdict(Counter)
    reps = Counter()
    for r in recs:
        d = r["id"][5:10]
        day[d]["発話"] += 1
        if r.get("packs"):
            day[d]["パックあり"] += 1
        if r.get("autocorrected"):
            day[d]["自動置き換え"] += 1
            reps.update(r["autocorrected"])
    print("  日付   発話  パックあり  自動置き換え")
    for d in sorted(day):
        v = day[d]
        print(f"  {d}  {v['発話']:>4}  {v['パックあり']:>9}  {v['自動置き換え']:>11}")
    if reps:
        print("\n  よく直した誤変換: " + "、".join(f"{k}（{n}）" for k, n in reps.most_common(10)))
    groups = {"パックあり": [r for r in recs if r.get("packs")], "パックなし": [r for r in recs if not r.get("packs")]}
    print("\n  伝達成功率（改善ループの判定）")
    for name, rs in groups.items():
        c = Counter(r.get("communication") for r in rs)
        judged = c["understood"] + c["corrected"]
        rate = f"{c['understood'] / judged:.1%}" if judged else "-"
        print(f"  {name}: {rate}（判定 {judged}、伝わらなかった {c['corrected']}）")
    print("\n  注意: パックの導入前後で話す内容が違うので、前後比較は目安。公平な比較は koe_bench.py build-packs")


def cmd_quality(a):
    from collections import defaultdict
    from statistics import median
    since = (datetime.now() - timedelta(days=a.days)).strftime("%Y-%m-%dT%H-%M-%S")
    recs = [r for r in load_records() if r["id"] >= since and r.get("quality")]
    if not recs:
        sys.exit("音質の指標が記録された発話がありません（Koe 0.2.1 以降で記録）")
    keys = ["level_db", "noise_db", "snr_db", "clip_ratio", "brightness"]

    def show(title, groups):
        print(f"\n== {title}")
        print("  " + "グループ".ljust(24) + "件数  " + "  ".join(k.ljust(10) for k in keys) + "  文字/秒")
        for name, rs in groups.items():
            vals = [median([r["quality"][k] for r in rs if k in r["quality"]] or [0]) for k in keys]
            rate = [len(r.get("raw") or "") / r["voiced_seconds"] for r in rs if (r.get("voiced_seconds") or 0) > 1]
            print("  " + str(name)[:24].ljust(24) + f"{len(rs):>4}  " + "  ".join(f"{v:<10}" for v in vals) + f"  {median(rate) if rate else 0:.1f}")

    by_comm = defaultdict(list)
    for r in recs:
        by_comm[r.get("communication") or "未判定"].append(r)
    show("伝達の判定別（中央値）", by_comm)
    by_dev = defaultdict(list)
    for r in recs:
        by_dev[r.get("device") or "-"].append(r)
    show("使ったマイク別（中央値）", by_dev)
    alt = [r for r in recs if r.get("alt_quality")]
    if alt:
        print(f"\n== 同じ発話のマイク違い（{len(alt)} 件、主のマイク → もう 1 本）")
        for k in keys:
            m = median([r["quality"].get(k, 0) for r in alt]); n = median([r["alt_quality"].get(k, 0) for r in alt])
            print(f"  {k:<10} {m} → {n}")
        print("  認識の比較は: python3 eval/koe_bench.py build-mics -o mics.json → show → score")


def cmd_set_draft(a):
    r = find(a.id)
    r["reference_draft"] = a.text
    save(r)
    print(f"set draft for {a.id}")


def cmd_review(a):
    drafts = [r for r in load_records() if r.get("reference_draft") and not r.get("reference")]
    print(f"{len(drafts)} 件の下書き。Enter=確定 / 文字を打つ=その文で確定 / s=スキップ / q=終了\n")
    for r in drafts:
        print(f"raw  : {r.get('raw')}")
        print(f"draft: {r['reference_draft']}")
        if r["_wav"].exists() and a.play:
            subprocess.run(["afplay", str(r["_wav"])])
        ans = input("> ").strip()
        if ans == "q":
            break
        if ans == "s":
            continue
        r["reference"] = ans or r["reference_draft"]
        save(r)
        print("  ✓\n")


def cmd_set_ref(a):
    r = find(a.id)
    r["reference"] = a.text
    save(r)
    print(f"set reference for {a.id}")


def labeled(use_drafts=False):
    recs = []
    for r in load_records():
        ref = r.get("reference") or (r.get("reference_draft") if use_drafts else None)
        if ref and r["_wav"].exists():
            r["_ref"] = ref
            recs.append(r)
    if not recs:
        sys.exit("正解付きのサンプルがありません。set-ref で reference を入れてください")
    return recs


def cmd_score(a):
    rows = []
    for r in labeled(a.drafts):
        row = {"id": r["id"], "raw": cer(r.get("raw"), r["_ref"])}
        if r.get("cleaned"):
            row["cleaned"] = cer(r["cleaned"], r["_ref"])
        rows.append(row)
    print("保存済みの結果（録音時の設定）")
    summarize(rows, ["raw", "cleaned"])


def cmd_run(a):
    recs = labeled(a.drafts)
    llm_prompt = Path(a.llm_prompt_file).read_text()
    server = start_server(a.model, a.prompt)
    rows = []
    try:
        for r in recs:
            t0 = time.time()
            raw = transcribe(r["_wav"])
            row = {"id": r["id"], "reference": r["_ref"], "draft": not r.get("reference"),
                   "raw_text": raw, "transcribe_ms": int((time.time() - t0) * 1000),
                   "raw": cer(raw, r["_ref"]), "baseline_raw": cer(r.get("raw"), r["_ref"])}
            if a.llm_model:
                t1 = time.time()
                cleaned = llm_clean(raw, a.llm_model, a.llm_endpoint, llm_prompt, os.environ.get("KOE_LLM_API_KEY"))
                row.update(cleaned_text=cleaned, clean_ms=int((time.time() - t1) * 1000),
                           cleaned=cer(cleaned, r["_ref"]))
            rows.append(row)
            print(f"  {r['id']}  raw {row['raw']:.1%}" + (f"  cleaned {row['cleaned']:.1%}" if "cleaned" in row else ""))
    finally:
        server.terminate()

    print(f"\n[{a.tag}] model={Path(a.model).name} llm={a.llm_model or '-'}"
          f"  confirmed={sum(1 for x in rows if not x['draft'])} draft={sum(1 for x in rows if x['draft'])}")
    summarize(rows, ["baseline_raw", "raw", "cleaned"])
    worst = sorted(rows, key=lambda x: -x.get("cleaned", x["raw"]))[:5]
    print("\n  ワースト5")
    for w in worst:
        print(f"   {w.get('cleaned', w['raw']):.0%}  ref: {w['reference']}\n        hyp: {w.get('cleaned_text', w['raw_text'])}")

    EVALS.mkdir(parents=True, exist_ok=True)
    out = EVALS / f"{time.strftime('%Y%m%d-%H%M%S')}-{a.tag}.json"
    out.write_text(json.dumps({"tag": a.tag, "model": str(a.model), "prompt": a.prompt,
                               "llm_model": a.llm_model, "llm_endpoint": a.llm_endpoint,
                               "llm_prompt_file": a.llm_prompt_file, "rows": rows},
                              ensure_ascii=False, indent=2))
    print(f"\n  saved: {out}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("list")
    s.add_argument("--unlabeled", action="store_true")
    s.add_argument("--limit", type=int, default=50)
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("pending")
    s.set_defaults(func=cmd_pending)

    s = sub.add_parser("unscanned")
    s.set_defaults(func=cmd_unscanned)

    s = sub.add_parser("mark-scanned")
    s.add_argument("ids", nargs="*")
    s.add_argument("--all", action="store_true", help="未処理の発話すべてに印を付ける")
    s.set_defaults(func=cmd_mark_scanned)

    s = sub.add_parser("misses")
    s.add_argument("--days", type=int, default=7)
    s.set_defaults(func=cmd_misses)

    s = sub.add_parser("trend")
    s.add_argument("--days", type=int, default=14)
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_trend)

    s = sub.add_parser("packs")
    s.add_argument("--days", type=int, default=14)
    s.set_defaults(func=cmd_packs)

    s = sub.add_parser("quality")
    s.add_argument("--days", type=int, default=14)
    s.set_defaults(func=cmd_quality)

    s = sub.add_parser("context")
    s.add_argument("ids", nargs="*")
    s.add_argument("--unscanned", action="store_true", help="辞書の更新に未使用の発話だけ")
    s.set_defaults(func=cmd_context)

    s = sub.add_parser("set-comm")
    s.add_argument("id")
    s.add_argument("outcome", choices=COMM)
    s.add_argument("--note")
    s.set_defaults(func=cmd_set_comm)

    s = sub.add_parser("comm")
    s.add_argument("--days", type=int, default=14)
    s.set_defaults(func=cmd_comm)

    s = sub.add_parser("set-draft")
    s.add_argument("id")
    s.add_argument("text")
    s.set_defaults(func=cmd_set_draft)

    s = sub.add_parser("review")
    s.add_argument("--play", action="store_true", help="録音を再生しながら確認する")
    s.set_defaults(func=cmd_review)

    s = sub.add_parser("set-ref")
    s.add_argument("id")
    s.add_argument("text")
    s.set_defaults(func=cmd_set_ref)

    s = sub.add_parser("score")
    s.add_argument("--drafts", action="store_true")
    s.set_defaults(func=cmd_score)

    s = sub.add_parser("run")
    s.add_argument("--tag", required=True)
    s.add_argument("--drafts", action="store_true")
    s.add_argument("--model", default=str(DEFAULT_MODEL))
    s.add_argument("--prompt", default="これで合ってる？はい、承知しました。それって本当？では、次の作業に進みましょう。")
    s.add_argument("--llm-model")
    s.add_argument("--llm-endpoint", default="http://localhost:11434/v1")
    s.add_argument("--llm-prompt-file", default=str(DEFAULT_LLM_PROMPT))
    s.set_defaults(func=cmd_run)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
