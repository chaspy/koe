#!/usr/bin/env python3
"""Does Apple's voice isolation help or hurt whisper? (#197, measurement only)

Public speech (the JSUT clips of public_bench.py) and public noise (DEMAND),
mixed in memory at fixed SNRs, each transcribed with the processing off and on.
The processing is AUSoundIsolation applied offline (eval/sound_isolation_cli.swift,
AVAudioEngine manual rendering): no microphone, no speaker. Only aggregate
numbers are printed and saved; no transcript leaves memory.

    python3 eval/voice_isolation_bench.py            # 100 JSUT clips + 60 term sentences
    python3 eval/voice_isolation_bench.py --noise OOFFICE PCAFETER

Needs: public_bench.py run once (JSUT cache), ffmpeg, swiftc, the whisper-server
of public_bench.py, and the turbo model of asr_bench.py (downloaded by revision
and SHA-256 into its cache when missing).
"""

import argparse
import array
import fcntl
import hashlib
import json
import math
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile
import wave
import zipfile

import public_bench as pb
import asr_bench as asb
from koe_bench import _autocorrect, _parse_glossary
from koe_eval import edit_distance

CACHE = Path.home() / 'Library/Caches/koe-eval/voice-isolation'
RATE = 16000
PROCESS_RATE = 48000      # AUSoundIsolation runs at the file's rate; 48 kHz like a Mac microphone
SNRS = (20, 15, 10)
ZERO_RUN_MS = 100
CLIPS = 100
# DEMAND (Thiemann, Ito, Vincent 2013), CC BY 4.0: https://zenodo.org/records/1227121
# SHA-256 of the 16 kHz zips (Zenodo lists MD5 only; these were taken from downloads that
# matched Zenodo's MD5 7b61cc2d… and 99927d14…).
DEMAND = {
    'OOFFICE': '7570c952f621990d0d71b8398107d9a78066254f883a5569abec9c233ffda358',
    'PCAFETER': '89be7194b83cd583c4b12f4bf7c19e9cf0e612b95312e9f4aedc968cd811bcd5',
}
DEMAND_URL = 'https://zenodo.org/records/1227121/files/{}_16k.zip?download=1'
HELPER = Path(__file__).resolve().parent / 'sound_isolation_cli.swift'
BOOTSTRAP = 2000


def read_pcm(path):
    with wave.open(str(path), 'rb') as w:
        if w.getnchannels() != 1 or w.getsampwidth() != 2 or w.getframerate() != RATE:
            raise ValueError(f'{path.name}: expected 16 kHz mono PCM16')
        return array.array('h', w.readframes(w.getnframes()))


def write_pcm(path, pcm):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())


def rms(pcm):
    return math.sqrt(sum(v * v for v in pcm) / len(pcm)) if pcm else 0.0


def zero_runs(pcm, rate=RATE, min_ms=ZERO_RUN_MS):
    """Runs of exact zeros of at least min_ms inside the voiced span (first to last
    non-zero sample), as Koe's SelfDiagnosis ZeroRuns. Returns (runs, ratio)."""
    nonzero = [i for i, v in enumerate(pcm) if v != 0]
    if not nonzero:
        return 0, 0.0
    first, last = nonzero[0], nonzero[-1]
    need = max(1, rate * min_ms // 1000)
    runs = covered = current = 0
    for v in pcm[first:last + 1]:
        if v == 0:
            current += 1
            continue
        if current >= need:
            runs += 1
            covered += current
        current = 0
    return runs, covered / (last - first + 1)


def noise_segment(noise, length, key):
    """A fixed piece of the noise for one clip: the offset comes from the clip's key."""
    if len(noise) < length:
        raise ValueError('noise shorter than the clip')
    offset = int(hashlib.sha256(key.encode()).hexdigest(), 16) % (len(noise) - length + 1)
    return noise[offset:offset + length]


def mix(speech, noise, snr_db):
    """speech + noise scaled so that 20·log10(rms(speech)/rms(noise)) = snr_db; clipped to 16 bit."""
    gain = rms(speech) / (rms(noise) * 10 ** (snr_db / 20)) if rms(noise) else 0.0
    return array.array('h', (max(-32768, min(32767, round(s + n * gain))) for s, n in zip(speech, noise)))


def paired_ci(a, b, seed=197, rounds=BOOTSTRAP):
    """95% bootstrap interval of the CER difference b − a over the same utterances.
    a and b are lists of (errors, length)."""
    rng = random.Random(seed)
    n = len(a)

    def diff(idx):
        la = sum(a[i][1] for i in idx)
        return sum(b[i][0] for i in idx) / la - sum(a[i][0] for i in idx) / la

    stats = sorted(diff([rng.randrange(n) for _ in range(n)]) for _ in range(rounds))
    return diff(range(n)), stats[int(rounds * 0.025)], stats[int(rounds * 0.975) - 1]


def fetch_noise(cache, name):
    """The first channel of a DEMAND environment as 16 kHz PCM16 (downloaded once, SHA-256-checked)."""
    out = cache / 'demand' / f'{name}.wav'
    if out.exists():
        return read_pcm(out)
    out.parent.mkdir(parents=True, exist_ok=True)
    archive = out.with_suffix('.zip')
    if not archive.exists():
        part = archive.with_suffix('.part')
        with pb.NETWORK.open(DEMAND_URL.format(name), timeout=600) as response, part.open('wb') as f:
            shutil.copyfileobj(response, f)
        if pb.digest(part) != DEMAND[name]:
            part.unlink()
            raise ValueError(f'{name}: checksum mismatch')
        part.replace(archive)
    with zipfile.ZipFile(archive) as z:
        member = next(n for n in z.namelist() if n.endswith('/ch01.wav'))
        raw = out.with_suffix('.ch01.wav')
        raw.write_bytes(z.read(member))
    subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(raw), '-ac', '1', '-ar', str(RATE),
                    '-c:a', 'pcm_s16le', str(out)], check=True)
    raw.unlink()
    return read_pcm(out)


def build_helper(cache):
    """Compile the Swift helper into the cache (rebuilt when its source changes)."""
    tag = hashlib.sha256(HELPER.read_bytes()).hexdigest()[:12]
    binary = cache / f'sound_isolation_cli-{tag}'
    if not binary.exists():
        cache.mkdir(parents=True, exist_ok=True)
        subprocess.run(['nice', '-n', '15', 'swiftc', '-O', str(HELPER), '-o', str(binary)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return binary


def isolate(helper, wavs, tmp):
    """Run the processing on 16 kHz WAVs (through 48 kHz float, back to 16 kHz PCM16 like Koe's capture)."""
    pairs, outs = [], []
    for i, wav in enumerate(wavs):
        hi, done = tmp / f'in{i}.wav', tmp / f'out{i}.wav'
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(wav), '-ac', '1', '-ar', str(PROCESS_RATE),
                        '-c:a', 'pcm_f32le', str(hi)], check=True)
        pairs += [str(hi), str(done)]
        outs.append(done)
    subprocess.run(['nice', '-n', '15', str(helper), *pairs], check=True)
    result = []
    for i, done in enumerate(outs):
        back = tmp / f'p{i}.wav'
        subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(done), '-ac', '1', '-ar', str(RATE),
                        '-c:a', 'pcm_s16le', str(back)], check=True)
        result.append(read_pcm(back))
    return result


def term_set(cache, entries):
    """The term sentences of asr_bench.py, spoken by the macOS voice (asr_bench.synth, cached by sentence)."""
    items = asb.term_items(entries)
    return [(read_pcm(wav), term) for wav, (term, _) in zip(asb.synth(cache, items), items)]


def cached_jsut(cache):
    """The JSUT clips public_bench.py already extracted (read locally; nothing is downloaded here)."""
    target = cache / 'jsut-v1.1-basic5000-0001-0200'
    refs = target / 'references.txt'
    if not refs.exists():
        raise SystemExit('JSUT clips missing: run python3 eval/public_bench.py once first')
    out = []
    for line in refs.read_text(encoding='utf-8').splitlines():
        key, reference = line.split(':', 1)
        out.append((target / f'{key}.wav', reference))
    return out


def conditions(noise_names):
    yield 'clean', None, None
    for name in noise_names:
        for snr in SNRS:
            yield f'{name}_{snr}dB', name, snr


def run(args):
    entries = _parse_glossary(pb.ROOT / 'packs' / 'developer.txt')
    prompt = pb.pack_prompt(entries)
    clips = [(read_pcm(w), ref, w.stem) for w, ref in cached_jsut(pb.CACHE)[:args.clips]]
    terms = term_set(args.cache, entries)[:args.terms]
    noises = {n: fetch_noise(args.cache, n) for n in args.noise}
    helper = build_helper(args.cache)
    model = asb.TURBO.fetch(pb.CACHE)
    results = {'clips': len(clips), 'terms': len(terms), 'zero_run_ms': ZERO_RUN_MS, 'conditions': {}}
    with pb.server(args.server, model, False) as url, tempfile.TemporaryDirectory(dir=args.cache) as tmpdir:
        tmp = Path(tmpdir)
        wav = tmp / 'u.wav'
        write_pcm(wav, clips[0][0])
        pb.transcribe(url, wav, prompt, False)  # warm-up, not counted

        def transcribe(pcm):
            write_pcm(wav, pcm)
            text, _ = pb.transcribe(url, wav, prompt, False)
            return _autocorrect(text, entries)

        for label, name, snr in conditions(args.noise):
            if pb_memory_low(args.min_free):
                raise MemoryError(f'memory free below {args.min_free}%')

            def noisy(pcm, key):
                return pcm if name is None else mix(pcm, noise_segment(noises[name], len(pcm), key + label), snr)

            plain = [noisy(pcm, key) for pcm, _, key in clips]
            plain_terms = [noisy(pcm, f'term{i}') for i, (pcm, _) in enumerate(terms)]
            paths = []
            for i, pcm in enumerate(plain + plain_terms):
                p = tmp / f'm{i}.wav'
                write_pcm(p, pcm)
                paths.append(p)
            processed = isolate(helper, paths, tmp)
            cond = {}
            for mode, speech, spoken in (('off', plain, plain_terms),
                                         ('on', processed[:len(plain)], processed[len(plain):])):
                per = []
                for pcm, (_, reference, _) in zip(speech, clips):
                    text = transcribe(pcm)
                    per.append((edit_distance(pb.normalize(text), pb.normalize(reference)), len(pb.normalize(reference))))
                hits = sum(asb.fold(term) in asb.fold(transcribe(pcm)) for pcm, (_, term) in zip(spoken, terms))
                zeros = sum(zero_runs(pcm)[0] > 0 for pcm in speech + spoken)
                cond[mode] = {'cer': sum(e for e, _ in per) / sum(n for _, n in per), 'per': per,
                              'terms_right': hits, 'zero_run_utterances': zeros}
                print(f'{label} {mode}: done', file=sys.stderr, flush=True)
            d, lo, hi = paired_ci(cond['off']['per'], cond['on']['per'])
            results['conditions'][label] = {
                mode: {k: v for k, v in cond[mode].items() if k != 'per'} for mode in ('off', 'on')}
            results['conditions'][label]['cer_diff'] = {'on_minus_off': d, 'ci95': [lo, hi]}
    return results


def pb_memory_low(min_free):
    """memory_pressure's free percentage below min_free (False when it cannot be read)."""
    try:
        out = subprocess.run(['memory_pressure'], capture_output=True, text=True, timeout=30).stdout
        free = int(out.strip().splitlines()[-1].rsplit(':', 1)[1].strip().rstrip('%'))
    except (OSError, ValueError, IndexError, subprocess.TimeoutExpired):
        return False
    return free < min_free


def table(results):
    n_utt = results['clips'] + results['terms']
    lines = ['| 条件 | 処理 | CER | CER の差（オン−オフ, 95% 区間） | 用語の正解 | ゼロ連続のある発話 |',
             '|---|---|---|---|---|---|']
    for label, c in results['conditions'].items():
        d = c['cer_diff']
        for mode in ('off', 'on'):
            m = c[mode]
            diff = (f"{d['on_minus_off'] * 100:+.1f} pt（{d['ci95'][0] * 100:+.1f}〜{d['ci95'][1] * 100:+.1f}）"
                    if mode == 'on' else '')
            lines.append(f"| {label} | {mode} | {m['cer'] * 100:.1f}% | {diff} | {m['terms_right']}/{results['terms']} "
                         f"| {m['zero_run_utterances']}/{n_utt} |")
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--cache', type=Path, default=CACHE)
    parser.add_argument('--server', type=Path, default=Path.home() / '.local/src/whisper.cpp/build-static/bin/whisper-server')
    parser.add_argument('--clips', type=int, default=CLIPS)
    parser.add_argument('--terms', type=int, default=asb.TERMS, help='term sentences (asr_bench.py has 60)')
    parser.add_argument('--noise', nargs='+', default=['OOFFICE'], choices=sorted(DEMAND))
    parser.add_argument('--min-free', type=int, default=30, help='stop when memory_pressure free %% drops below this')
    args = parser.parse_args()
    args.cache.mkdir(parents=True, exist_ok=True)
    with (args.cache / 'run.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        results = run(args)
    (args.cache / 'results.json').write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print(table(results))


if __name__ == '__main__':
    main()
