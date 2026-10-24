#!/usr/bin/env python3
"""Compare Japanese ASR engines on the Mac with the same data and metrics (#180).

Data (public or synthetic only, never a real person's voice):
- JSUT v1.1 BASIC5000 fixed clips (public_bench.py), trimmed and joined into
  length buckets like audio_ctx_bench.py: single clips < 5 s, joins of 5-28 s.
- Terms: sentences with terms from packs/developer.txt, spoken by the macOS
  voice "Kyoko" (`say`), generated into the cache. A term counts as right when
  the hypothesis contains it (NFKC, case and spaces ignored).

Per engine and condition: transcription seconds (median / p90) per bucket, CER
before and after notation normalisation (raw: spaces removed; normalised: NFKC
and punctuation removed as in public_bench.normalize), term accuracy, peak RSS
of the engine process, model size and licence. Conditions: "base" (the base
prompt, no autocorrect) and "pack" (prompt with the developer pack and pack
autocorrect, as Koe runs by default). Engines without a prompt get autocorrect
only; engines that take vocabulary hints (SpeechAnalyzer's contextual strings) also
get "hints": every pack term as a hint, plus autocorrect.

One engine is resident at a time; the process runs at nice 15 with 4 threads.
Models are downloaded once into the cache outside the repository, pinned by
revision and SHA-256. Only numbers are printed and stored; no transcript is
kept. Usage:

    python3 eval/public_bench.py            # once, caches the JSUT clips
    python3 eval/asr_bench.py               # all engines
    python3 eval/asr_bench.py --engines whisper-turbo-metal
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import unicodedata

import public_bench as pb
import audio_ctx_bench as ab
from koe_bench import BASE_PROMPT, _autocorrect, _parse_glossary
from koe_eval import edit_distance

PER_JOIN_BUCKET = 20   # joined utterances per bucket (single clips: SINGLE_MAX)
SINGLE_MAX = 60
TERMS = 60             # sentences in the terms set
VOICE = 'Kyoko'
TEMPLATES = ('{}の設定を確認してください。', '次は{}を使って直します。', 'さっきの{}の件、どうなりましたか。')
HF = 'https://huggingface.co'


class Model:
    """A model file pinned by revision and SHA-256, downloaded into the cache."""

    def __init__(self, repo, revision, name, sha256, size, licence):
        self.repo, self.revision, self.name, self.sha256, self.size, self.licence = repo, revision, name, sha256, size, licence

    def path(self, cache):
        return cache / 'asr-models' / self.name

    def fetch(self, cache):
        path = self.path(cache)
        if not path.exists():
            path.parent.mkdir(parents=True, exist_ok=True)
            part = path.with_suffix('.part')
            url = f'{HF}/{self.repo}/resolve/{self.revision}/{self.name}'
            with pb.NETWORK.open(url, timeout=600) as response, part.open('wb') as out:
                shutil.copyfileobj(response, out)
            if pb.digest(part) != self.sha256:
                part.unlink()
                raise ValueError(f'{self.name}: checksum mismatch')
            part.replace(path)
        if pb.digest(path) != self.sha256:
            raise ValueError(f'{self.name}: cached file checksum mismatch')
        return path


TURBO = Model('ggerganov/whisper.cpp', pb.MODEL_REV, 'ggml-large-v3-turbo.bin',
              '1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69', 1624555275, 'MIT')
KOTOBA = Model('kotoba-tech/kotoba-whisper-v2.0-ggml', 'e3a0cf6a62b95911703cfb97d819292e058f12c3',
               'ggml-kotoba-whisper-v2.0.bin', 'eff70a8a236e731abba774ba71e1f6d0fce53302137208c32207e694e0bf4546',
               1519521155, 'Apache-2.0')


class WhisperServerEngine:
    """whisper.cpp's whisper-server with a ggml model (Koe's request fields)."""

    prompts = True
    hints = False  # run_engine reads this for every engine (missing since #191: AttributeError)

    def __init__(self, name, model, extra=()):
        self.name, self.model, self.extra = name, model, list(extra)
        self.model_mb, self.licence = model.size // 1_000_000, model.licence
        self.proc, self.url = None, None

    def start(self, cache, executable):
        path = self.model.fetch(cache)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        self.url = f'http://127.0.0.1:{port}'
        args = [str(executable), '-m', str(path), '-l', 'ja', '--host', '127.0.0.1', '--port', str(port),
                '-t', '4', '--prompt', BASE_PROMPT, *self.extra]
        self.proc = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 300
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError(f'{self.name}: server exited during startup')
            try:
                with pb.NETWORK.open(self.url + '/health', timeout=1) as response:
                    if response.status == 200:
                        return
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError(f'{self.name}: startup timed out')
            time.sleep(0.25)

    def transcribe(self, wav, prompt):
        # the whole window: Koe's macOS default since #167
        return pb.transcribe(self.url, wav, prompt, False, ctx=0)

    def rss_mb(self):
        return rss_mb(self.proc.pid) if self.proc else 0

    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
            self.proc = None


# whisper.cpp's prebuilt Core ML encoder for turbo (runs on the Neural Engine), same pinned revision as the model
COREML_ENCODER = Model('ggerganov/whisper.cpp', pb.MODEL_REV, 'ggml-large-v3-turbo-encoder.mlmodelc.zip',
                       '84bedfe895bd7b5de6e8e89a0803dfc5addf8c0c5bc4c937451716bf7cf7988a', 1173393014, 'MIT')
WHISPER_SRC = Path.home() / '.local/src/whisper.cpp'
WHISPER_REV = '0c7be69'  # the revision Koe builds whisper-server from


class CoreMLWhisperEngine(WhisperServerEngine):
    """whisper.cpp large-v3-turbo with the Core ML encoder (Neural Engine) and the
    decoder on Metal. whisper-server is built once with WHISPER_COREML from the same
    source revision as Koe's, into the cache. The first request also compiles the
    Core ML model for this Mac (excluded with the warm-up)."""

    def __init__(self):
        super().__init__('whisper-turbo-coreml', TURBO)

    def start(self, cache, executable):
        enc = COREML_ENCODER.fetch(cache)
        mlmodelc = enc.parent / 'ggml-large-v3-turbo-encoder.mlmodelc'
        if not mlmodelc.exists():
            subprocess.run(['unzip', '-q', '-o', str(enc), '-d', str(enc.parent)], check=True)
        build = cache / 'whisper-coreml-build'
        server = build / 'bin' / 'whisper-server'
        if not server.exists():
            rev = subprocess.run(['git', '-C', str(WHISPER_SRC), 'rev-parse', '--short=7', 'HEAD'],
                                 capture_output=True, text=True).stdout.strip()
            if rev != WHISPER_REV:
                raise RuntimeError(f'whisper.cpp source is at {rev}, expected {WHISPER_REV}')
            subprocess.run(['cmake', '-S', str(WHISPER_SRC), '-B', str(build), '-DWHISPER_COREML=1',
                            '-DBUILD_SHARED_LIBS=OFF', '-DCMAKE_BUILD_TYPE=Release'], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['nice', '-n', '15', 'cmake', '--build', str(build), '-j', '4', '--target', 'whisper-server'],
                           check=True, stdout=subprocess.DEVNULL)
        self.model_mb += COREML_ENCODER.size // 1_000_000
        super().start(cache, server)


class ProcessEngine:
    """A resident helper process: one WAV path per line on stdin, one JSON line
    {"text", "seconds"} per line on stdout. Subclasses build the command."""

    prompts = False
    hints = False  # takes vocabulary hints: tab-separated after the path

    def command(self, cache):
        raise NotImplementedError

    def start(self, cache, executable):
        self.proc = subprocess.Popen(self.command(cache), stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

    def transcribe(self, wav, prompt):
        self.proc.stdin.write(str(wav) + ('\t' + prompt if prompt else '') + '\n')
        self.proc.stdin.flush()
        line = self.proc.stdout.readline()
        if not line:
            raise RuntimeError(f'{self.name}: helper exited')
        out = json.loads(line)
        return out['text'], out['seconds']

    def rss_mb(self):
        return rss_mb(self.proc.pid) if getattr(self, 'proc', None) else 0

    def stop(self):
        if getattr(self, 'proc', None):
            self.proc.stdin.close()
            self.proc.wait(timeout=60)
            self.proc = None


class SpeechAnalyzerEngine(ProcessEngine):
    """Apple SpeechAnalyzer / SpeechTranscriber (macOS 26, ja_JP, on-device) through
    speechanalyzer_cli.swift. No prompt; the pack terms can go in as contextual strings.
    The speech model is part of macOS and runs partly in system processes, so the RSS is
    the helper's only."""

    name, model_mb, licence = 'apple-speechanalyzer', 0, 'Apple (part of macOS)'
    hints = True
    module = 'speech'

    def command(self, cache):
        exe = cache / 'speechanalyzer_cli'
        src = Path(__file__).with_name('speechanalyzer_cli.swift')
        if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
            subprocess.run(['swiftc', '-O', '-o', str(exe), str(src)], check=True)
        return [str(exe), self.module]


class DictationEngine(SpeechAnalyzerEngine):
    """The same helper with DictationTranscriber (the model behind macOS dictation,
    preset shortDictation) instead of SpeechTranscriber."""

    name, module = 'apple-dictation', 'dictation'


# Same archive and sha256 as Koe for Windows (windows/core/engine.go)
PARAKEET_NAME = 'sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8'
PARAKEET_URL = f'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{PARAKEET_NAME}.tar.bz2'
PARAKEET_SHA = '4b0a800ef29f4f4c8667339bf6f60d5bfdc2852ddc9dc5741aea65b6f8d1306b'
SHERPA_RELEASE = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/{}.tar.bz2'


class SherpaEngine(ProcessEngine):
    """A sherpa-onnx offline model through sherpa_cli.py, 4 threads, greedy. The archive is
    pinned by SHA-256 and unpacked into the cache. Engines without hotwords: autocorrect only."""

    def __init__(self, name, kind, archive, sha256, licence, weights, provider='cpu', hints=False):
        self.name, self.kind, self.archive, self.sha256, self.licence = name, kind, archive, sha256, licence
        self.weights, self.provider, self.hints, self.model_mb = weights, provider, hints, 0

    def command(self, cache):
        model = cache / 'asr-models' / self.archive
        if not (model / self.weights[0]).exists():
            archive = cache / 'asr-models' / f'{self.archive}.tar.bz2'
            archive.parent.mkdir(parents=True, exist_ok=True)
            if not archive.exists():
                part = archive.with_suffix('.part')
                with pb.NETWORK.open(SHERPA_RELEASE.format(self.archive), timeout=600) as response, part.open('wb') as out:
                    shutil.copyfileobj(response, out)
                part.replace(archive)
            if pb.digest(archive) != self.sha256:
                archive.unlink()
                raise ValueError(f'{self.name}: checksum mismatch')
            subprocess.run(['tar', 'xjf', str(archive), '-C', str(archive.parent)], check=True)
        self.model_mb = sum((model / w).stat().st_size for w in self.weights) // 1_000_000
        venv = cache / 'asr-venv'
        if not (venv / 'bin' / 'python').exists():
            subprocess.run([sys.executable, '-m', 'venv', str(venv)], check=True)
            subprocess.run([str(venv / 'bin' / 'pip'), 'install', '-q', '--require-hashes', '--only-binary', ':all:',
                            '-r', str(Path(__file__).with_name('asr_requirements.txt'))], check=True)
        return [str(venv / 'bin' / 'python'), str(Path(__file__).with_name('sherpa_cli.py')),
                self.kind, str(model), '4', self.provider]


def ParakeetEngine(provider='cpu'):
    """Parakeet-ja through sherpa-onnx (4 threads), like Koe for Windows. CTC head, greedy:
    no prompt or hotwords, autocorrect only."""
    return SherpaEngine('parakeet-ja-sherpa-' + provider, 'nemo_ctc', PARAKEET_NAME, PARAKEET_SHA,
                        'CC-BY-4.0 (model), Apache-2.0 (sherpa-onnx)', ['model.int8.onnx'], provider)


# #180 optional candidates. SHA-256: Moonshine and Qwen3 from the digests GitHub publishes for
# the release assets; ReazonSpeech's asset has none, so it is the SHA-256 of the download used here.
MOONSHINE = ('sherpa-onnx-moonshine-tiny-ja-quantized-2026-02-27',
             '880305c9a6c33572ab269ff9731977ea42ca34c8cffcdd5d99558a9ea2b47cc2')
QWEN3 = ('sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25',
         '393f8a14e2f5fb96746aaab342997a40641001fbd5bf9592a080a8329178ee96')
REAZON = ('sherpa-onnx-zipformer-ja-reazonspeech-2024-08-01', 'e0981d0d5d7b446d41010831b59091ebf57d2aa7b79980f67ca37af460b5842d')


class WhisperKitEngine(ProcessEngine):
    """WhisperKit (Core ML; the koe-ios engine) through whisperkit_cli/, a resident Swift helper.
    The helper is built with SwiftPM into the cache (WhisperKit pinned in Package.swift and
    Package.resolved); the model files are pinned file by file in whisperkit_models.json (SHA-256,
    Hugging Face revision). The prompt goes in as prompt tokens, like whisper.cpp's initial prompt."""

    prompts = True
    licence = 'MIT (WhisperKit, model)'
    manifest = Path(__file__).with_name('whisperkit_models.json')

    def __init__(self, name, model):
        self.name, self.model, self.model_mb = name, model, 0

    def fetch(self, cache):
        m = json.loads(self.manifest.read_text())
        folder = cache / 'asr-models' / 'whisperkit' / self.model
        for rel, sha in m['models'][self.model].items():
            path = folder / rel
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                part = path.with_name(path.name + '.part')
                url = f"{HF}/{m['repo']}/resolve/{m['revision']}/{self.model}/{rel}"
                with pb.NETWORK.open(url, timeout=600) as response, part.open('wb') as out:
                    shutil.copyfileobj(response, out)
                part.replace(path)
            if pb.digest(path) != sha:
                path.unlink()
                raise ValueError(f'{self.name}: {rel} checksum mismatch')
        self.model_mb = sum((folder / rel).stat().st_size for rel in m['models'][self.model]) // 1_000_000
        return folder

    def command(self, cache):
        folder = self.fetch(cache)
        build = cache / 'whisperkit-build'
        subprocess.run(['nice', '-n', '15', 'swift', 'build', '-c', 'release', '-j', '4', '--scratch-path', str(build),
                        '--package-path', str(Path(__file__).with_name('whisperkit_cli'))],
                       check=True, stdout=subprocess.DEVNULL)
        return [str(build / 'release' / 'whisperkit_cli'), str(folder)]


ENGINES = {
    'whisper-turbo-metal': lambda: WhisperServerEngine('whisper-turbo-metal', TURBO),
    'kotoba-whisper-v2-metal': lambda: WhisperServerEngine('kotoba-whisper-v2-metal', KOTOBA),
    'whisper-turbo-coreml': CoreMLWhisperEngine,
    'apple-speechanalyzer': SpeechAnalyzerEngine,
    'apple-dictation': DictationEngine,
    'parakeet-ja-sherpa-cpu': ParakeetEngine,
    'parakeet-ja-sherpa-coreml': lambda: ParakeetEngine('coreml'),
    'moonshine-tiny-ja-sherpa-cpu': lambda: SherpaEngine(
        'moonshine-tiny-ja-sherpa-cpu', 'moonshine', *MOONSHINE,
        'Moonshine Community License (non-commercial; model), Apache-2.0 (sherpa-onnx)',
        ['encoder_model.ort', 'decoder_model_merged.ort']),
    'qwen3-asr-0.6b-sherpa-cpu': lambda: SherpaEngine(
        'qwen3-asr-0.6b-sherpa-cpu', 'qwen3', *QWEN3, 'Apache-2.0 (model, sherpa-onnx)',
        ['conv_frontend.onnx', 'encoder.int8.onnx', 'decoder.int8.onnx'], hints=True),
    'whisperkit-turbo': lambda: WhisperKitEngine('whisperkit-turbo', 'openai_whisper-large-v3-v20240930'),
    'whisperkit-turbo-626mb': lambda: WhisperKitEngine('whisperkit-turbo-626mb', 'openai_whisper-large-v3-v20240930_626MB'),
    'reazonspeech-zipformer-sherpa-cpu': lambda: SherpaEngine(
        'reazonspeech-zipformer-sherpa-cpu', 'transducer', *REAZON, 'Apache-2.0 (model, sherpa-onnx)',
        ['encoder-epoch-99-avg-1.int8.onnx', 'decoder-epoch-99-avg-1.onnx', 'joiner-epoch-99-avg-1.int8.onnx']),
}


def rss_mb(pid):
    out = subprocess.run(['ps', '-o', 'rss=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) // 1024 if out.isdigit() else 0


def available_gb():
    """Free + inactive + speculative memory (what macOS can hand out without swapping much)."""
    out = subprocess.run(['vm_stat'], capture_output=True, text=True).stdout
    pages, size = 0, 16384
    for line in out.splitlines():
        if 'page size of' in line:
            size = int(line.split('page size of')[1].split()[0])
        for key in ('Pages free', 'Pages inactive', 'Pages speculative'):
            if line.startswith(key):
                pages += int(line.split(':')[1].strip().rstrip('.'))
    return pages * size / 1e9


def hint_line(entries):
    """Every pack term once, in pack order, tab-separated for the helper's stdin line."""
    return '\t'.join(dict.fromkeys(t for t, _ in entries if '\t' not in t))


def fold(text):
    """For term matching: NFKC, lower case, no spaces."""
    return ''.join(unicodedata.normalize('NFKC', text).lower().split())


def raw_chars(text):
    """CER before notation normalisation: only spaces removed."""
    return ''.join(text.split())


def term_items(entries):
    """Deterministic term set: every k-th pack term that has katakana or latin letters."""
    terms = [t for t, _ in entries if any('゠' <= c <= 'ヿ' or c.isascii() and c.isalpha() for c in t)]
    step = max(1, len(terms) // TERMS)
    picked = terms[::step][:TERMS]
    return [(term, TEMPLATES[i % len(TEMPLATES)].format(term)) for i, term in enumerate(picked)]


def synth(cache, items):
    """Speak each sentence with the macOS voice into 16 kHz mono WAV (cached by sentence, so a
    pack change that moves a term never pairs a sentence with another sentence's audio)."""
    out = cache / 'asr-terms'
    out.mkdir(parents=True, exist_ok=True)
    wavs = []
    for _, sentence in items:
        wav = out / (hashlib.sha256(sentence.encode()).hexdigest()[:16] + '.wav')
        if not wav.exists():
            aiff = wav.with_suffix('.aiff')
            subprocess.run(['say', '-v', VOICE, '-o', str(aiff), sentence], check=True)
            subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', str(aiff), '-ac', '1', '-ar', '16000',
                            '-c:a', 'pcm_s16le', str(wav)], check=True)
            aiff.unlink()
        wavs.append(wav)
    return wavs


def length_sets(clips):
    sets = ab.utterances(clips)
    out = {}
    for label, _, _ in ab.BUCKETS:
        out[label] = sets[label][:SINGLE_MAX if label == ab.SINGLE[0][0] else PER_JOIN_BUCKET]
    return out


def p90(xs):
    xs = sorted(xs)
    return xs[max(0, int(len(xs) * 0.9 + 0.5) - 1)]


def clean_variants(engine, sets, terms, entries):
    """The usual conditions: (name, utterance sets, term WAVs, prompt or hints, pack for autocorrect)."""
    conds = (('none', '', []), ('base', BASE_PROMPT, []), ('pack', pb.pack_prompt(entries), entries))
    if not engine.prompts:  # no prompt: only plain and autocorrect
        conds = (('none', '', []), ('pack', '', entries))
    if engine.hints:
        conds += (('hints', hint_line(entries), entries),)
    return [(name, sets, terms[1], prompt, pack) for name, prompt, pack in conds]


def noisy_variants(engine, cache, sets, terms, entries, noise_name, snrs):
    """Koe's default condition (pack; and hints for engines that take them) on the same utterances
    and term sentences with DEMAND noise mixed in (voice_isolation_bench.mix, a fixed piece per clip)."""
    import voice_isolation_bench as vib
    noise = vib.fetch_noise(vib.CACHE, noise_name)  # the DEMAND cache of #197 (SHA-256-pinned)
    out = []
    for snr in snrs:
        label = f'{noise_name}_{snr}dB'
        noisy = {b: [(vib.mix(pcm, vib.noise_segment(noise, len(pcm), f'{b}{k}{label}'), snr), ref)
                     for k, (pcm, ref) in enumerate(items)] for b, items in sets.items()}
        folder = cache / 'asr-noise' / label
        folder.mkdir(parents=True, exist_ok=True)
        wavs = []
        for twav in terms[1]:
            pcm = vib.read_pcm(twav)
            path = folder / twav.name
            ab.write_wav(path, vib.mix(pcm, vib.noise_segment(noise, len(pcm), twav.name + label), snr))
            wavs.append(path)
        conds = [('pack', pb.pack_prompt(entries) if engine.prompts else '')]
        if engine.hints:
            conds.append(('hints', hint_line(entries)))
        out += [(f'{name}@{label}', noisy, wavs, prompt, entries) for name, prompt in conds]
    return out


def measure(engine, wav, sets, term_items_, term_wavs, prompt, pack, min_gb, peak):
    """One condition: CER and times by length bucket, then the term sentences."""
    c = {'buckets': {}, 'err_raw': 0, 'err_norm': 0, 'len_raw': 0, 'len_norm': 0}
    for label, items in sets.items():
        times, berr, blen, empty = [], 0, 0, 0
        for pcm, reference in items:
            if available_gb() < min_gb:
                raise MemoryError(f'available memory below {min_gb} GB')
            ab.write_wav(wav, pcm)
            text, secs = engine.transcribe(wav, prompt)
            text = _autocorrect(text, pack) if pack else text
            times.append(secs)
            c['err_raw'] += edit_distance(raw_chars(text), raw_chars(reference))
            c['len_raw'] += len(raw_chars(reference))
            e = edit_distance(pb.normalize(text), pb.normalize(reference))
            c['err_norm'] += e
            c['len_norm'] += len(pb.normalize(reference))
            berr, blen, empty = berr + e, blen + len(pb.normalize(reference)), empty + (not text.strip())
            peak = max(peak, engine.rss_mb())
        c['buckets'][label] = {'n': len(times), 'median': statistics.median(times), 'p90': p90(times),
                               'cer': berr / blen, 'empty': empty}
    hits, ttimes = 0, []
    for (term, _), twav in zip(term_items_, term_wavs):
        text, secs = engine.transcribe(twav, prompt)
        text = _autocorrect(text, pack) if pack else text
        hits += fold(term) in fold(text)
        ttimes.append(secs)
    c['terms'] = {'n': len(ttimes), 'right': hits, 'median': statistics.median(ttimes)}
    return c, peak


def run_engine(engine, cache, executable, sets, terms, entries, min_gb, variants=None):
    """variants: from clean_variants (default) or noisy_variants."""
    engine.start(cache, executable)
    rows = {'engine': engine.name, 'model_mb': engine.model_mb, 'licence': engine.licence, 'conditions': {}}
    try:
        peak = engine.rss_mb()
        with tempfile.TemporaryDirectory(dir=cache) as tmp:
            wav = Path(tmp) / 'u.wav'
            ab.write_wav(wav, sets[ab.SINGLE[0][0]][0][0])
            engine.transcribe(wav, BASE_PROMPT if engine.prompts else '')  # warm-up, excluded
            for cond, cset, twavs, prompt, pack in variants or clean_variants(engine, sets, terms, entries):
                rows['conditions'][cond], peak = measure(engine, wav, cset, terms[0], twavs, prompt, pack, min_gb, peak)
                print(f'{engine.name} {cond}: done', file=sys.stderr, flush=True)
        rows['peak_rss_mb'] = peak
    finally:
        engine.stop()
    return rows


def bucket_table(results, what, cell):
    """One row per engine and condition, one column per length bucket."""
    lines = ['', '| Engine | Condition | ' + ' | '.join(f'{label} {what}' for label, _, _ in ab.BUCKETS) + ' |',
             '|---|---|' + '---:|' * len(ab.BUCKETS)]
    for r in results:
        for cond, c in r['conditions'].items():
            lines.append(f"| {r['engine']} | {cond} | " + ' | '.join(cell(c['buckets'][label]) for label, _, _ in ab.BUCKETS) + ' |')
    return lines


def table(results):
    lines = ['| Engine | Condition | CER raw (%) | CER normalised (%) | Terms right | Median s (<5 s) | p90 s (<5 s) | '
             'Median s (12.8-16 s) | Median s (24-28 s) | Peak RSS (MB) | Model (MB) | Licence |',
             '|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|']
    for r in results:
        for cond, c in r['conditions'].items():
            b = c['buckets']
            lines.append(f"| {r['engine']} | {cond} | {c['err_raw'] / c['len_raw'] * 100:.2f} | "
                         f"{c['err_norm'] / c['len_norm'] * 100:.2f} | {c['terms']['right']}/{c['terms']['n']} | "
                         f"{b['<5 s']['median']:.3f} | {b['<5 s']['p90']:.3f} | {b['12.8-16 s']['median']:.3f} | "
                         f"{b['24-28 s']['median']:.3f} | {r['peak_rss_mb']} | {r['model_mb']} | {r['licence']} |")
    lines += bucket_table(results, 'median / p90 (s)', lambda b: f"{b['median']:.3f} / {b['p90']:.3f}")
    lines += bucket_table(results, 'CER % (empty)', lambda b: f"{b['cer'] * 100:.1f} ({b['empty']})")
    for r in results:
        if r.get('error'):
            lines.append(f"\n{r['engine']}: not measured ({r['error']})")
    return '\n'.join(lines)


def result_order(r, order):
    """Engines in ENGINES order, each engine's noisy run right after its clean one."""
    base = r['engine'].split('@')[0]
    return (order.index(base) if base in order else len(order), '@' in r['engine'])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--cache', type=Path, default=pb.CACHE)
    parser.add_argument('--server', type=Path, default=Path.home() / '.local/src/whisper.cpp/build-static/bin/whisper-server')
    parser.add_argument('--engines', nargs='+', default=list(ENGINES), choices=list(ENGINES))
    parser.add_argument('--min-available-gb', type=float, default=6.0, help='stop when free+inactive memory drops below this')
    parser.add_argument('--noise', choices=('OOFFICE', 'PCAFETER'),
                        help='measure only Koe\'s default condition with this DEMAND noise mixed in (saved as <engine>@noise)')
    parser.add_argument('--snr', type=int, nargs='+', default=[20, 15, 10])
    args = parser.parse_args()
    if not args.server.is_file() or not shutil.which('ffmpeg'):
        parser.error('whisper-server and ffmpeg are required')
    if os.getpriority(os.PRIO_PROCESS, 0) < 15:
        os.setpriority(os.PRIO_PROCESS, 0, 15)
    for name in ('OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS'):
        os.environ[name] = '4'
    args.cache.mkdir(parents=True, exist_ok=True)
    with (args.cache / 'run.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        started = time.monotonic()
        sets = length_sets(pb.prepare(args.cache))
        entries = _parse_glossary(pb.ROOT / 'packs' / 'developer.txt')
        items = term_items(entries)
        terms = (items, synth(args.cache, items))
        # earlier runs of other engines are kept (engines can be measured in turns, e.g. when memory is short)
        saved = args.cache / 'asr-results.json'
        suffix = '@noise' if args.noise else ''
        results = [r for r in (json.loads(saved.read_text()) if saved.exists() else [])
                   if r['engine'] not in [n + suffix for n in args.engines]]
        for name in args.engines:
            try:
                engine = ENGINES[name]()
                variants = noisy_variants(engine, args.cache, sets, terms, entries, args.noise, args.snr) if args.noise else None
                row = run_engine(engine, args.cache, args.server, sets, terms, entries, args.min_available_gb, variants)
                row['engine'] += suffix
                results.append(row)
            except MemoryError:
                raise
            except Exception as error:  # one engine failing does not stop the others; only the type is kept
                print(f'{name}: failed ({type(error).__name__})', file=sys.stderr, flush=True)
                results.append({'engine': name + suffix, 'error': type(error).__name__, 'conditions': {}})
            saved.write_text(json.dumps(results, indent=2))
        order = list(ENGINES)
        results.sort(key=lambda r: result_order(r, order))
        print(table([r for r in results if r['conditions']] + [r for r in results if not r['conditions']]))
        print(f'elapsed_seconds={time.monotonic() - started:.1f}')
        print(f'server_sha256={pb.digest(args.server)}')


if __name__ == '__main__':
    try:
        main()
    except (Exception, KeyboardInterrupt) as error:
        print(f'Benchmark failed ({type(error).__name__}: {str(error)[:120]}); no partial table emitted.', file=sys.stderr)
        sys.exit(1)
