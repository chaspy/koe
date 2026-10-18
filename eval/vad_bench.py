#!/usr/bin/env python3
"""Silero VAD before whisper vs. Koe's energy trim, on public JSUT clips plus
synthetic padding, noise and silence-only cases. Only aggregate numbers leave
memory; no transcript is printed or stored."""

import argparse
import fcntl
import io
import math
import os
from pathlib import Path
import shutil
import statistics
import sys
import time
import urllib.request
import uuid
import wave

import numpy as np

import public_bench as pb
from koe_bench import BASE_PROMPT
from koe_eval import edit_distance

RATE = 16000
# Silero VAD v5 ONNX weights: MIT, pinned to a repository commit and SHA-256.
# https://github.com/snakers4/silero-vad
VAD_COMMIT = '1e261b036686cd0017d500ee96acd1c4ba572a9d'
VAD_SHA = '1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3'
VAD_LICENSE_SHA = '2e63e9a38b6e8fc0c7bc37ce174caca1862870856c6daf5697cfb785e925520b'
VAD_URL = f'https://raw.githubusercontent.com/snakers4/silero-vad/{VAD_COMMIT}/'
CHUNK, CONTEXT = 512, 64  # 32 ms frames at 16 kHz, 64-sample context (v5)
# The same Silero v5 weights converted for whisper.cpp's built-in VAD (MIT),
# pinned Hugging Face revision and SHA-256. This is what whisper-server loads.
GGML_VAD_REV = '9ffd54a1e1ee413ddf265af9913beaf518d1639b'
GGML_VAD_NAME = 'ggml-silero-v5.1.2.bin'
GGML_VAD_SHA = '29940d98d42b91fbd05ce489f3ecf7c72f0a42f027e4875919a28fb4c04ea2cf'
GGML_VAD_URL = f'https://huggingface.co/ggml-org/whisper-vad/resolve/{GGML_VAD_REV}/{GGML_VAD_NAME}'
CONDITIONS = ('raw', 'koe', 'vad', 'vad-tight', 'koe+server-vad')
# Koe (macOS main.swift trimSilence / hallucinations; windows/core/audio.go).
KOE_WINDOW, KOE_THRESHOLD = int(RATE * 0.03), 330.0
PAD_BEFORE, PAD_AFTER = 0.25, 0.3
HALLUCINATIONS = {'ご視聴ありがとうございました', 'ご視聴ありがとうございました。',
                  'ありがとうございました', 'ありがとうございました。',
                  'おやすみなさい', 'おやすみなさい。',
                  '(音楽)', '(拍手)', '[音楽]', '[BLANK_AUDIO]'}
STOCK_PHRASES = ['(音楽)', '（音楽）', '[音楽]', '(拍手)', '（拍手）', '[拍手]', '(笑)', '[笑]',
                 '[BLANK_AUDIO]', '[blank_audio]', '(字幕)', 'ご視聴ありがとうございました']
# Synthetic variants: leading/trailing seconds and white-noise floor in dBFS.
# -60 dBFS (RMS 33) is below Koe's energy threshold; -38 dBFS (RMS 412) is
# above it, so the energy trim no longer finds the edges.
VARIANTS = (('clean', 0.0, 0.0, None), ('padded', 1.5, 2.5, -60.0), ('noisy', 1.5, 2.5, -38.0))
SILENCE_LEVELS = (-60.0, -45.0, -38.0)
SILENCE_PER_LEVEL = 20


def fetch(cache, remote, sha, url=VAD_URL, prefix=f'silero-vad-{VAD_COMMIT[:7]}-'):
    path = cache / (prefix + remote.rsplit('/', 1)[-1])
    if not path.exists():
        temporary = path.with_suffix('.part')
        with pb.NETWORK.open(url + remote, timeout=120) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output)
        if pb.digest(temporary) != sha:
            raise ValueError('VAD download checksum mismatch')
        temporary.replace(path)
    if pb.digest(path) != sha:
        raise ValueError('Cached VAD checksum mismatch')
    return path


class SileroVAD:
    """Streaming Silero v5 inference on one CPU thread; state reset per clip."""

    def __init__(self, model):
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        options.log_severity_level = 3
        self.session = ort.InferenceSession(str(model), options, providers=['CPUExecutionProvider'])
        self.version = ort.__version__

    def probabilities(self, pcm):
        samples = pcm.astype(np.float32) / 32768.0
        state = np.zeros((2, 1, 128), np.float32)
        context = np.zeros(CONTEXT, np.float32)
        rate = np.array(RATE, np.int64)
        probabilities = []
        for start in range(0, len(samples) - CHUNK + 1, CHUNK):
            chunk = samples[start:start + CHUNK]
            output, state = self.session.run(None, {
                'input': np.concatenate([context, chunk])[None], 'state': state, 'sr': rate})
            probabilities.append(float(output[0][0]))
            context = chunk[-CONTEXT:]
        return probabilities


def speech_span(probabilities, threshold=0.5, min_speech=0.25, min_silence=0.1):
    """First speech start and last speech end in seconds, or None (Silero's
    hysteresis: on at threshold, off below threshold - 0.15 for min_silence)."""
    frame = CHUNK / RATE
    segments, start, silent_since = [], None, None
    for index, p in enumerate(probabilities):
        now = index * frame
        if p >= threshold:
            if start is None:
                start = now
            silent_since = None
        elif start is not None and p < threshold - 0.15:
            if silent_since is None:
                silent_since = now
            elif now - silent_since >= min_silence:
                segments.append((start, silent_since))
                start, silent_since = None, None
    if start is not None:
        segments.append((start, silent_since if silent_since is not None else len(probabilities) * frame))
    segments = [s for s in segments if s[1] - s[0] >= min_speech]
    return (segments[0][0], segments[-1][1]) if segments else None


def koe_trim(pcm):
    """Koe's energy trim: 30 ms RMS above 330, 0.25 s before / 0.3 s after."""
    n = len(pcm)
    if n <= KOE_WINDOW:
        return None
    squares = pcm.astype(np.float64) ** 2

    def loud(i):
        end = min(i + KOE_WINDOW, n)
        return math.sqrt(squares[i:end].sum() / (end - i)) > KOE_THRESHOLD

    first = next((i for i in range(0, n, KOE_WINDOW) if loud(i)), None)
    if first is None:
        return None
    last = next(i for i in range(n - KOE_WINDOW, -1, -KOE_WINDOW) if loud(i))
    return max(0, first - int(RATE * PAD_BEFORE)), min(n, last + KOE_WINDOW + int(RATE * PAD_AFTER))


def vad_trim(vad, pcm, before, after):
    span = speech_span(vad.probabilities(pcm))
    if span is None:
        return None
    return max(0, int((span[0] - before) * RATE)), min(len(pcm), int((span[1] + after) * RATE))


def read_pcm(path):
    with wave.open(str(path), 'rb') as audio:
        if audio.getframerate() != RATE or audio.getnchannels() != 1 or audio.getsampwidth() != 2:
            raise ValueError('Expected 16 kHz mono PCM16')
        return np.frombuffer(audio.readframes(audio.getnframes()), '<i2')


def wav_bytes(pcm):
    buffer = io.BytesIO()
    with wave.open(buffer, 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(RATE)
        audio.writeframes(pcm.astype('<i2').tobytes())
    return buffer.getvalue()


def noise(rng, samples, dbfs):
    return rng.normal(0.0, 32768.0 * 10 ** (dbfs / 20), samples)


def synthesize(pcm, rng, lead, trail, dbfs):
    if dbfs is None:
        return pcm
    signal = np.concatenate([np.zeros(int(lead * RATE)), pcm.astype(np.float64), np.zeros(int(trail * RATE))])
    return np.clip(signal + noise(rng, len(signal), dbfs), -32768, 32767).astype('<i2')


def silence_clips(rng):
    clips = []
    for dbfs in SILENCE_LEVELS:
        for _ in range(SILENCE_PER_LEVEL):
            clips.append(np.clip(noise(rng, int(rng.uniform(1.0, 6.0) * RATE), dbfs), -32768, 32767).astype('<i2'))
    return clips


def transcribe(url, data, prompt, audio_ctx, temperature_inc=None, server_vad=False):
    fields = [('response_format', 'text'), ('prompt', prompt), ('temperature', '0.0'),
              ('audio_ctx', str(audio_ctx))]
    if temperature_inc is not None:
        fields.append(('temperature_inc', temperature_inc))
    if server_vad:
        # whisper.cpp's own Silero pass: speech segments are concatenated,
        # each padded by 250 ms; nothing is transcribed when none is found.
        fields += [('vad', 'true'), ('vad_speech_pad_ms', '250')]
    boundary = uuid.uuid4().hex
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
             for name, value in fields]
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
                 'Content-Type: audio/wav\r\n\r\n'.encode() + data + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    request = urllib.request.Request(url + '/inference', data=b''.join(parts),
                                    headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})
    started = time.perf_counter()
    with pb.NETWORK.open(request, timeout=300) as response:
        text = response.read().decode('utf-8').strip()
    return text, time.perf_counter() - started


def remove_stock_phrases(text):
    for phrase in STOCK_PHRASES:
        text = text.replace(phrase + '。', '').replace(phrase, '')
    return ' '.join(text.split())


def run_clip(url, pcm, condition, vad):
    """Returns (text or None when nothing would be pasted, gate seconds,
    whisper seconds, sent audio seconds, dropped-before-whisper, dropped-after)."""
    started = time.perf_counter()
    server_vad = condition == 'koe+server-vad'
    if condition == 'raw':
        span = (0, len(pcm))
    elif condition == 'koe' or server_vad:
        span = koe_trim(pcm)
    elif condition == 'vad':
        span = vad_trim(vad, pcm, PAD_BEFORE, PAD_AFTER)
    else:
        span = vad_trim(vad, pcm, 0.1, 0.1)
    gate = time.perf_counter() - started
    if span is None:
        return None, gate, 0.0, 0.0, True, False
    cut = pcm[span[0]:span[1]]
    seconds = len(cut) / RATE
    data = wav_bytes(cut)
    text, elapsed = transcribe(url, data, BASE_PROMPT, pb.audio_ctx(seconds), server_vad=server_vad)
    if condition == 'raw':
        return text, gate, elapsed, seconds, False, False
    # Koe's checks after transcription (macOS transcribe()); same for every gate.
    if not text or text in HALLUCINATIONS:
        if seconds >= 1.0:
            text, retry = transcribe(url, data, '', pb.audio_ctx(seconds), server_vad=server_vad)
            elapsed += retry
        if not text or text in HALLUCINATIONS:
            return None, gate, elapsed, seconds, False, True
    if pb.repetitive(text) or any(p in text for p in STOCK_PHRASES):
        text, retry = transcribe(url, data, '', 0, '0.2', server_vad=server_vad)
        elapsed += retry
        text = remove_stock_phrases(text)
        if not text:
            return None, gate, elapsed, seconds, False, True
    return text, gate, elapsed, seconds, False, False


def summarize(rows, references):
    """rows: run_clip results; references: normalized reference per row."""
    edits = total_ref = head = tail = 0
    for (text, *_), ref in zip(rows, references):
        hyp = pb.normalize(text or '')
        edits += edit_distance(hyp, ref)
        total_ref += len(ref)
        head += len(ref) >= 2 and hyp[:2] != ref[:2]
        tail += len(ref) >= 2 and hyp[-2:] != ref[-2:]
    totals = sorted(row[1] + row[2] for row in rows)
    return {
        'cer': edits / total_ref if total_ref else float('nan'),
        'median': statistics.median(totals), 'p95': totals[math.ceil(len(totals) * .95) - 1],
        'gate_ms': statistics.median(row[1] for row in rows) * 1000,
        'sent': sum(row[3] for row in rows),
        'skipped': sum(row[4] for row in rows), 'dropped': sum(row[5] for row in rows),
        'pasted': sum(row[0] is not None and pb.normalize(row[0]) != '' for row in rows),
        'head': head, 'tail': tail,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=pb.CACHE)
    parser.add_argument('--server', type=Path, default=Path.home() / '.local/src/whisper.cpp/build-static/bin/whisper-server')
    parser.add_argument('--turbo-model', type=Path, default=Path.home() / 'Library/Application Support/Koe/models/ggml-large-v3-turbo.bin')
    parser.add_argument('--limit', type=int, default=len(pb.IDS), help='clips per variant (smoke runs)')
    parser.add_argument('--seed', type=int, default=8, help='noise generator seed')
    parser.add_argument('--conditions', default=','.join(CONDITIONS),
                        help='comma-separated subset of ' + ', '.join(CONDITIONS))
    args = parser.parse_args()
    cache = args.cache.expanduser().resolve()
    if cache == pb.ROOT or pb.ROOT in cache.parents or (cache / '.git').exists():
        parser.error('Cache must be outside the repository')
    if not args.server.is_file() or not args.turbo_model.is_file() or not shutil.which('ffmpeg'):
        parser.error('whisper-server, turbo model and ffmpeg are required')
    if os.getpriority(os.PRIO_PROCESS, 0) < 15:
        os.setpriority(os.PRIO_PROCESS, 0, 15)
    for name in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS'):
        os.environ[name] = '4'
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / 'run.lock').open('w') as lock:  # Shared with public_bench.py.
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = time.monotonic()
        clips = pb.prepare(cache)[:args.limit]
        fetch(cache, 'LICENSE', VAD_LICENSE_SHA)
        vad = SileroVAD(fetch(cache, 'src/silero_vad/data/silero_vad.onnx', VAD_SHA))
        ggml_vad = fetch(cache, GGML_VAD_NAME, GGML_VAD_SHA, GGML_VAD_URL.rsplit('/', 1)[0] + '/', '')
        conditions = [c for c in args.conditions.split(',') if c]
        if not set(conditions) <= set(CONDITIONS):
            parser.error('Unknown condition')
        references = [pb.normalize(reference) for _, reference in clips]
        originals = [read_pcm(wav) for wav, _ in clips]
        rng = np.random.default_rng(args.seed)
        sets = [(label, [synthesize(pcm, rng, lead, trail, dbfs) for pcm in originals], references)
                for label, lead, trail, dbfs in VARIANTS]
        silence = silence_clips(rng)
        sets.append(('silence', silence, [''] * len(silence)))
        results = []
        with pb.server(args.server, args.turbo_model, False, ['-vm', str(ggml_vad)]) as url:
            transcribe(url, wav_bytes(originals[0]), BASE_PROMPT, pb.audio_ctx(3))  # Excluded warm-up.
            for label, pcms, refs in sets:
                for condition in conditions:
                    rows = [run_clip(url, pcm, condition, vad) for pcm in pcms]
                    results.append((label, condition, summarize(rows, refs)))
                    print(f'{label}/{condition}: completed={len(rows)}', file=sys.stderr, flush=True)
        print('| Audio | Gate | Clips | CER (%) | Median (s) | p95 (s) | Gate (ms) | Sent audio (s) '
              '| Skipped | Dropped | Pasted | Head | Tail |')
        print('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
        for label, condition, m in results:
            cer = '-' if label == 'silence' else f'{m["cer"] * 100:.2f}'
            head = tail = '-'
            if label != 'silence':
                head, tail = m['head'], m['tail']
            n = len(silence) if label == 'silence' else len(clips)
            print(f'| {label} | {condition} | {n} | {cer} | {m["median"]:.3f} | {m["p95"]:.3f} | '
                  f'{m["gate_ms"]:.1f} | {m["sent"]:.1f} | {m["skipped"]} | {m["dropped"]} | '
                  f'{m["pasted"]} | {head} | {tail} |')
        print(f'elapsed_seconds={time.monotonic() - started:.1f}')
        print(f'server_sha256={pb.digest(args.server)}')
        print(f'turbo_sha256={pb.digest(args.turbo_model)}')
        print(f'vad_sha256={VAD_SHA}')
        print(f'ggml_vad_sha256={GGML_VAD_SHA}')
        print(f'onnxruntime={vad.version} numpy={np.__version__} seed={args.seed}')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        # Exceptions from network/decoding must never expose response bodies.
        print(f'Benchmark failed ({type(error).__name__}); no partial table emitted.', file=sys.stderr)
        sys.exit(1)
