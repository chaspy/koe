#!/usr/bin/env python3
"""Fixed public JSUT benchmark. Only aggregate metrics leave memory."""

import argparse
from collections import Counter
from contextlib import contextmanager
import fcntl
import hashlib
import io
import math
import os
from pathlib import Path
import re
import shutil
import socket
import statistics
import subprocess
import sys
import time
import unicodedata
import urllib.request
import uuid
import wave
import zipfile

from koe_bench import BASE_PROMPT, _autocorrect, _parse_glossary
from koe_eval import edit_distance

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path.home() / 'Library/Caches/koe-public-bench'
# JSUT v1.1: official audio terms (non-commercial research/personal use),
# text CC-BY-SA 4.0 etc.; retain the archive's license beside the download.
# https://sites.google.com/site/shinnosuketakamichi/publication/jsut
DATA_URL = 'https://ss-takashi.sakura.ne.jp/corpus/jsut_ver1.1.zip'
DATA_SIZE = 2688749844
DATA_ETAG = '"a0431114-55f35b14be600"'
IDS = tuple(f'BASIC5000_{i:04d}' for i in range(1, 201))
MODEL_REV = '5359861c739e955e79d9a303bcbc70fb988958b1'
SMALL_NAME = 'ggml-small-q5_1.bin'
SMALL_SHA = 'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb'
# Direct connections only: a proxy could rewrite the Range / ETag answers the
# version checks below depend on. Behind a mandatory proxy, run elsewhere.
NETWORK = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class RemoteZip(io.RawIOBase):
    """Seekable, version-checked range reader; never download the whole corpus."""

    def __init__(self):
        self.position = 0

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=0):
        self.position = offset + (0, self.position, DATA_SIZE)[whence]
        if self.position < 0:
            raise ValueError('Invalid archive offset')
        return self.position

    def read(self, size=-1):
        end = DATA_SIZE if size < 0 else min(DATA_SIZE, self.position + size)
        if end <= self.position:
            return b''
        req = urllib.request.Request(DATA_URL, headers={
            'Range': f'bytes={self.position}-{end - 1}', 'If-Match': DATA_ETAG})
        with NETWORK.open(req, timeout=120) as response:
            expected = f'bytes {self.position}-{end - 1}/{DATA_SIZE}'
            if (response.status != 206 or response.headers.get('ETag') != DATA_ETAG
                    or response.headers.get('Content-Range') != expected):
                raise ValueError('Dataset version or range response changed')
            data = response.read(end - self.position + 1)
        if len(data) != end - self.position:
            raise ValueError('Incomplete archive range')
        self.position = end
        return data


def atomic_write(path, data):
    temporary = path.with_suffix(path.suffix + '.part')
    temporary.write_bytes(data)
    temporary.replace(path)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def prepare(cache):
    """Extract only selected files; archive names never become local paths."""
    target = cache / 'jsut-v1.1-basic5000-0001-0200'
    target.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(RemoteZip()) as archive:
        names = archive.namelist()
        licenses = [n for n in names if Path(n).name.upper().startswith(('LICENSE', 'LICENCE'))]
        if not licenses:
            raise ValueError('Dataset license missing')
        for i, name in enumerate(licenses):
            atomic_write(target / f'LICENSE-{i}.txt', archive.read(name))
        transcript = next(n for n in names if n.endswith('/basic5000/transcript_utf8.txt'))
        references = dict(line.split(':', 1) for line in
                          archive.read(transcript).decode('utf-8').splitlines() if line)
        # Keep just the fixed subset references outside the repository.
        atomic_write(target / 'references.txt', '\n'.join(
            f'{key}:{references[key]}' for key in IDS).encode('utf-8'))
        for index, key in enumerate(IDS, 1):
            wav = target / f'{key}.wav'
            if not wav.exists():
                name = next(n for n in names if n.endswith(f'/basic5000/wav/{key}.wav'))
                source = target / 'source.wav'
                atomic_write(source, archive.read(name))
                partial = target / 'converted.wav'
                subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-threads', '1',
                                '-i', str(source), '-ac', '1', '-ar', '16000',
                                '-c:a', 'pcm_s16le', '-threads', '1', str(partial)],
                               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                partial.replace(wav)
                source.unlink()
            if index % 25 == 0:
                print(f'prepared={index}/{len(IDS)}', file=sys.stderr, flush=True)
    return [(target / f'{key}.wav', references[key]) for key in IDS]


def small_model(cache):
    path = cache / SMALL_NAME
    if not path.exists():
        # Whisper weights: MIT, pinned Hugging Face revision and SHA-256.
        url = f'https://huggingface.co/ggerganov/whisper.cpp/resolve/{MODEL_REV}/{SMALL_NAME}'
        temporary = path.with_suffix('.part')
        with NETWORK.open(url, timeout=120) as response, temporary.open('wb') as output:
            shutil.copyfileobj(response, output)
        if digest(temporary) != SMALL_SHA:
            raise ValueError('Model checksum mismatch')
        temporary.replace(path)
    if digest(path) != SMALL_SHA:
        raise ValueError('Cached model checksum mismatch')
    return path


def normalize(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text)
                   if not c.isspace() and not unicodedata.category(c).startswith('P'))


def repetitive(text):
    """Koe thresholds: sentence x3, word x5, non-numeric 2–6 chars x6."""
    sentences = Counter(p.strip() for p in re.split(r'[。.!！?？\n ]+', text) if len(p.strip()) >= 4)
    if any(n >= 3 for n in sentences.values()):
        return True
    words = [p for p in re.split(r'[、,，。 　！？!?\n]+', text) if p]
    if any(len(set(words[i:i + 5])) == 1 for i in range(len(words) - 4)):
        return True
    for i in range(len(text)):
        for size in range(2, 7):
            unit = text[i:i + size]
            if len(unit) == size and unit.strip('0123456789') and text[i:i + size * 6] == unit * 6:
                return True
    return False


def pack_prompt(entries):
    terms, length = [], 0
    for term, _ in entries:
        if term not in terms and length + len(term) <= 120:
            terms.append(term)
            length += len(term) + 1
    return ('、'.join(terms) + '。' if terms else '') + BASE_PROMPT


def audio_ctx(seconds):
    return 0 if seconds >= 30 else min(1500, max(768, math.ceil(seconds * 55 - 1e-9) + 64))


@contextmanager
def server(executable, model, windows, extra=()):
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    args = [str(executable), '-m', str(model), '-l', 'ja', '--host', '127.0.0.1',
            '--port', str(port), '-t', '4', '--prompt', BASE_PROMPT, *extra]
    if windows:
        args += ['-bs', '1', '-bo', '1', '-fa', '-ng']
    proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.monotonic() + 180
        while True:
            if proc.poll() is not None:
                raise RuntimeError('Server exited during startup')
            try:
                with NETWORK.open(url + '/health', timeout=1) as response:
                    if response.status == 200:
                        break
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError('Server startup timed out')
            time.sleep(0.25)
        yield url
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def transcribe(url, wav, prompt, windows, ctx=None):
    """`ctx` overrides Koe's automatic audio_ctx (0 = the whole 30 s window)."""
    if ctx is None:
        with wave.open(str(wav), 'rb') as audio:
            ctx = audio_ctx(audio.getnframes() / audio.getframerate())
    fields = [('response_format', 'text'), ('prompt', prompt), ('temperature', '0.0'),
              ('audio_ctx', str(ctx))]
    if windows:
        fields.append(('temperature_inc', '0.0'))
    boundary = uuid.uuid4().hex
    parts = [f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode()
             for name, value in fields]
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
                 'Content-Type: audio/wav\r\n\r\n'.encode() + wav.read_bytes() + b'\r\n')
    parts.append(f'--{boundary}--\r\n'.encode())
    request = urllib.request.Request(url + '/inference', data=b''.join(parts),
                                    headers={'Content-Type': f'multipart/form-data; boundary={boundary}'})
    started = time.perf_counter()
    with NETWORK.open(request, timeout=300) as response:
        # Garbled output can cut a multibyte character; count it as errors, do not crash.
        text = response.read().decode('utf-8', errors='replace').strip()
    return text, time.perf_counter() - started


def metrics(rows):
    times = sorted(row[2] for row in rows)
    return (sum(row[0] for row in rows) / sum(row[1] for row in rows),
            statistics.median(times), times[math.ceil(len(times) * .95) - 1],
            sum(row[3] for row in rows))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=CACHE)
    parser.add_argument('--server', type=Path, default=Path.home() / '.local/src/whisper.cpp/build-static/bin/whisper-server')
    parser.add_argument('--turbo-model', type=Path, default=Path.home() / 'Library/Application Support/Koe/models/ggml-large-v3-turbo.bin')
    # Koe enables only `developer` by default; keep the "packs" conditions equal to that.
    parser.add_argument('--packs', nargs='+', default=['developer'], metavar='NAME', help='pack names under packs/ (default: developer, like Koe)')
    args = parser.parse_args()
    cache = args.cache.expanduser().resolve()
    if cache == ROOT or ROOT in cache.parents or (cache / '.git').exists():
        parser.error('Cache must be outside the repository')
    if not args.server.is_file() or not args.turbo_model.is_file() or not shutil.which('ffmpeg'):
        parser.error('whisper-server, turbo model and ffmpeg are required')
    if os.getpriority(os.PRIO_PROCESS, 0) < 15:
        os.setpriority(os.PRIO_PROCESS, 0, 15)
    for name in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS'):
        os.environ[name] = '4'
    cache.mkdir(parents=True, exist_ok=True)
    # Prevent concurrent benchmark processes from sharing the cache or GPU.
    with (cache / 'run.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = time.monotonic()
        clips = prepare(cache)
        small = small_model(cache)
        entries = [entry for name in args.packs for entry in _parse_glossary(ROOT / 'packs' / f'{name}.txt')]
        results = []
        for model, windows, conditions in (
            (args.turbo_model, False, [('turbo-base', []), ('turbo-packs', entries)]),
            (small, True, [('small-cpu-packs', entries)]),
        ):
            with server(args.server, model, windows) as url:
                for label, pack in conditions:
                    prompt = pack_prompt(pack)
                    transcribe(url, clips[0][0], prompt, windows)  # Excluded warm-up.
                    rows = []
                    for index, (wav, reference) in enumerate(clips, 1):
                        raw, elapsed = transcribe(url, wav, prompt, windows)
                        hyp, ref = normalize(_autocorrect(raw, pack)), normalize(reference)
                        rows.append((edit_distance(hyp, ref), len(ref), elapsed, repetitive(raw)))
                        if index % 25 == 0:
                            print(f'{label}: completed={index}/{len(clips)}', file=sys.stderr, flush=True)
                    results.append((label, metrics(rows)))
        print('| Condition | Clips | CER (%) | Median (s) | p95 (s) | Repetitive outputs |')
        print('|---|---:|---:|---:|---:|---:|')
        for label, (cer, median, p95, repeats) in results:
            print(f'| {label} | {len(clips)} | {cer * 100:.2f} | {median:.3f} | {p95:.3f} | {repeats} |')
        print(f'elapsed_seconds={time.monotonic() - started:.1f}')
        print(f'server_sha256={digest(args.server)}')
        print(f'turbo_sha256={digest(args.turbo_model)}')
        print(f'small_sha256={SMALL_SHA}')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        # Exceptions from network/decoding must never expose response bodies.
        print(f'Benchmark failed ({type(error).__name__}); no partial table emitted.', file=sys.stderr)
        sys.exit(1)
