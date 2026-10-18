#!/usr/bin/env python3
"""Compare Koe's shrunk encoder window (auto audio_ctx) with the whole window,
by utterance length (issue #165).

Uses the 200 cached JSUT clips of public_bench.py (run that once first, or let
this script fetch them the same way). Clips are trimmed of edge silence like
Koe's energy trim, and consecutive clips are joined with a 0.3 s pause into
utterances of 10-28 s, since the public subset is mostly short. Each utterance
is sent to large-v3-turbo (Metal) with the Koe prompt (base prompt + the
`developer` pack) at temperature 0, once with the old auto window and once with
the whole window. Only aggregate numbers are printed; no text is stored.
"""

import argparse
import array
import fcntl
import os
from pathlib import Path
import sys
import tempfile
import time
import unicodedata
import wave

import public_bench as pb
from koe_bench import _autocorrect, _parse_glossary
from koe_eval import edit_distance

RATE = 16000
PAUSE = int(0.3 * RATE)
EDGE = 500           # ~-36 dBFS: below this at the edges counts as silence
PAD = int(0.1 * RATE)
# (label, low, high) in seconds of audio; the first bucket is single clips.
SINGLE = (('<5 s', 0, 5),)
BUCKETS = SINGLE + (('5-7.5 s', 5, 7.5), ('7.5-10 s', 7.5, 10), ('10-12.8 s', 10, 12.8), ('12.8-16 s', 12.8, 16),
           ('16-20 s', 16, 20), ('20-24 s', 20, 24), ('24-28 s', 24, 28))
PER_BUCKET = 30
GARBLED = 0.5        # an utterance with CER above this is unusable


def trimmed(path):
    with wave.open(str(path), 'rb') as audio:
        pcm = array.array('h', audio.readframes(audio.getnframes()))
    loud = [i for i, v in enumerate(pcm) if abs(v) > EDGE]
    if not loud:
        return pcm
    return pcm[max(0, loud[0] - PAD):loud[-1] + PAD]


def utterances(clips):
    """Deterministic: every single clip under 5 s goes to the shortest bucket, then
    greedy joins of consecutive clips (wrapping around) until each longer
    bucket has PER_BUCKET."""
    pieces = [(trimmed(wav), reference) for wav, reference in clips]
    out = {label: [] for label, _, _ in BUCKETS}
    for pcm, reference in pieces:
        for label, low, high in SINGLE:
            if low <= len(pcm) / RATE < high:
                out[label].append((pcm, reference))
    start = 0
    for label, low, high in BUCKETS[len(SINGLE):]:
        tries = 0
        while len(out[label]) < PER_BUCKET and tries < len(pieces) * 2:
            pcm, refs, i = array.array('h'), [], start
            while len(pcm) / RATE < low:
                if pcm:
                    pcm.extend([0] * PAUSE)
                pcm.extend(pieces[i % len(pieces)][0])
                refs.append(pieces[i % len(pieces)][1])
                i += 1
            if len(pcm) / RATE < high:
                out[label].append((pcm, ''.join(refs)))
                start = i
            else:
                start += 1
            tries += 1
    return out


def write_wav(path, pcm):
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(RATE)
        audio.writeframes(pcm.tobytes())


def foreign_script(text):
    """Letters outside Japanese, Latin and Greek-free CJK: Hangul, Cyrillic, etc."""
    for c in text:
        if not c.isalpha():
            continue
        name = unicodedata.name(c, '')
        if not name.startswith(('CJK', 'HIRAGANA', 'KATAKANA', 'LATIN', 'FULLWIDTH LATIN',
                                'HALFWIDTH KATAKANA', 'IDEOGRAPHIC')):
            return True
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=pb.CACHE)
    parser.add_argument('--server', type=Path, default=Path.home() / '.local/src/whisper.cpp/build-static/bin/whisper-server')
    parser.add_argument('--turbo-model', type=Path, default=Path.home() / 'Library/Application Support/Koe/models/ggml-large-v3-turbo.bin')
    args = parser.parse_args()
    if not args.server.is_file() or not args.turbo_model.is_file():
        parser.error('whisper-server and the turbo model are required')
    if os.getpriority(os.PRIO_PROCESS, 0) < 15:
        os.setpriority(os.PRIO_PROCESS, 0, 15)
    args.cache.mkdir(parents=True, exist_ok=True)
    with (args.cache / 'run.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = time.monotonic()
        sets = utterances(pb.prepare(args.cache))
        entries = _parse_glossary(pb.ROOT / 'packs' / 'developer.txt')
        prompt = pb.pack_prompt(entries)
        rows = []
        with tempfile.TemporaryDirectory(dir=args.cache) as tmp, pb.server(args.server, args.turbo_model, False) as url:
            wav = Path(tmp) / 'utterance.wav'
            write_wav(wav, sets[SINGLE[0][0]][0][0])
            pb.transcribe(url, wav, prompt, False)  # Excluded warm-up.
            for label, _, _ in BUCKETS:
                stats = {}
                for pcm, reference in sets[label]:
                    write_wav(wav, pcm)
                    seconds = len(pcm) / RATE
                    ref = pb.normalize(reference)
                    for name, ctx in (('auto', pb.audio_ctx(seconds)), ('full', 0)):
                        raw, elapsed = pb.transcribe(url, wav, prompt, False, ctx=ctx)
                        errors = edit_distance(pb.normalize(_autocorrect(raw, entries)), ref)
                        s = stats.setdefault(name, {'err': 0, 'len': 0, 'times': [], 'garbled': 0,
                                                    'foreign': 0, 'invalid': 0, 'ctx': []})
                        s['err'] += errors
                        s['len'] += len(ref)
                        s['times'].append(elapsed)
                        s['garbled'] += errors / max(1, len(ref)) > GARBLED
                        s['foreign'] += foreign_script(raw)
                        s['invalid'] += '\ufffd' in raw  # not valid UTF-8: Koe reads it as empty
                        s['ctx'].append(ctx)
                rows.append((label, len(sets[label]), stats))
                print(f'{label}: done', file=sys.stderr, flush=True)
        print('| Length | Utterances | auto ctx | CER auto (%) | CER full (%) | Garbled auto / full | '
              'Foreign script auto / full | Invalid UTF-8 auto / full | Median auto (s) | Median full (s) |')
        print('|---|---:|---|---:|---:|---:|---:|---:|---:|---:|')
        for label, n, st in rows:
            a, f = st['auto'], st['full']
            med = lambda t: sorted(t)[len(t) // 2]
            print(f"| {label} | {n} | {min(a['ctx'])}-{max(a['ctx'])} | {a['err'] / a['len'] * 100:.2f} | "
                  f"{f['err'] / f['len'] * 100:.2f} | {a['garbled']} / {f['garbled']} | "
                  f"{a['foreign']} / {f['foreign']} | {a['invalid']} / {f['invalid']} | {med(a['times']):.3f} | {med(f['times']):.3f} |")
        print(f'elapsed_seconds={time.monotonic() - started:.1f}')
        print(f'server_sha256={pb.digest(args.server)}')
        print(f'turbo_sha256={pb.digest(args.turbo_model)}')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f'Benchmark failed ({type(error).__name__}); no partial table emitted.', file=sys.stderr)
        sys.exit(1)
