#!/usr/bin/env python3
"""Time each stage from key release to paste, with the same audio on any Mac.

Standard library only. The audio is synthesized with `say` (fixed Japanese
sentences, no personal data), so the Mac needs nothing but Koe installed.

  python3 eval/paste_bench.py                # borrow the running Koe's whisper-server
  python3 eval/paste_bench.py --own          # start a separate server (takes the madoguchi whisper lock)
  python3 eval/paste_bench.py --stress 8     # also measure with 8 busy CPU processes

Output is numbers only: machine model, chip, Koe version, load, and per-length
median / p90 of the whisper request. Transcripts are never printed or stored.
Koe's fixed stages are listed beside it (tail recording 0.25 s, paste ~0.1 s),
so `total` estimates release → paste for that utterance length.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid

KOE_APP = Path.home() / 'Applications/Koe.app'
KOE_DATA = Path.home() / 'Library/Application Support/Koe'
LOCK = Path.home() / '.config/madoguchi/locks/whisper'
NETWORK = urllib.request.build_opener(urllib.request.ProxyHandler({}))
# Koe's base prompt (macos/Sources/Koe/main.swift Settings.prompt default).
PROMPT = 'これで合ってる？はい、承知しました。それって本当？では、次の作業に進みましょう。'
SENTENCE = ('今日は午後から会議があるので、それまでに資料をまとめておきます。'
            '終わったら結果を共有して、次の作業に進みましょう。')
# Target lengths in seconds; the sentence is repeated and cut to reach them.
LENGTHS = (3, 8, 15, 25)
TAIL_MS = 250   # Recorder.tailSeconds: Koe keeps recording 0.25 s after release.
PASTE_MS = 95   # Median of release_to_paste − stop − transcribe − prompt in Koe's history.


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout.strip()


def machine():
    koe = sh('defaults', 'read', str(KOE_APP / 'Contents/Info.plist'), 'CFBundleShortVersionString') or '?'
    return {
        'model': sh('sysctl', '-n', 'hw.model'),
        'chip': sh('sysctl', '-n', 'machdep.cpu.brand_string'),
        'cores': os.cpu_count(),
        'perf_cores': sh('sysctl', '-n', 'hw.perflevel0.physicalcpu'),
        'mem_gb': round(int(sh('sysctl', '-n', 'hw.memsize') or 0) / 2**30),
        'macos': platform.mac_ver()[0],
        'koe': koe,
    }


def voice():
    names = [line.split()[0] for line in sh('say', '-v', '?').splitlines() if 'ja_JP' in line]
    return 'Kyoko' if 'Kyoko' in names else (names[0] if names else None)


def synth(work, v):
    """One 16 kHz mono WAV per target length."""
    out = {}
    for sec in LENGTHS:
        aiff, wav = work / f'{sec}.aiff', work / f'{sec}.wav'
        text = SENTENCE * math.ceil(sec / 6)
        subprocess.run(['say', '-v', v, '-o', str(aiff), text], check=True)
        # Trim to the target length (afconvert has no trim; cut the PCM ourselves).
        subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
        out[sec] = trim(wav, sec)
    return out


def trim(wav, sec):
    import wave
    with wave.open(str(wav), 'rb') as w:
        frames = w.readframes(min(w.getnframes(), int(sec * w.getframerate())))
        params = w.getparams()
    with wave.open(str(wav), 'wb') as w:
        w.setparams(params)
        w.writeframes(frames)
    return wav


def running_server():
    """Port of the whisper-server the running Koe started (from its lifetime record)."""
    for rec in sorted((KOE_DATA / 'servers').glob('*.json')):
        pid = json.loads(rec.read_text())['server']['pid']
        out = sh('lsof', '-nP', '-a', '-p', str(pid), '-iTCP', '-sTCP:LISTEN')
        for line in out.splitlines()[1:]:
            return 'http://' + line.split()[8]
    return None


def start_server(model):
    if not LOCK.parent.is_dir():
        LOCK.parent.mkdir(parents=True)
    try:
        LOCK.mkdir()
    except FileExistsError:
        sys.exit(f'whisper lock is taken ({LOCK}); try later')
    (LOCK / 'owner').write_text(f'paste_bench pid={os.getpid()}\n')
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    binary = KOE_APP / 'Contents/MacOS/whisper-server'
    # Same arguments as Koe (main.swift WhisperServer.start), VAD off.
    proc = subprocess.Popen([str(binary), '-m', str(model), '-l', 'ja', '--host', '127.0.0.1',
                             '--port', str(port), '-t', '4', '--prompt', PROMPT],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    url = f'http://127.0.0.1:{port}'
    deadline = time.monotonic() + 180
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break
        try:
            with NETWORK.open(url + '/health', timeout=1):
                return proc, url
        except OSError:
            time.sleep(0.25)
    stop_server(proc)
    sys.exit('whisper-server did not start')


def stop_server(proc):
    if proc:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    for f in (LOCK / 'owner',):
        f.unlink(missing_ok=True)
    try:
        LOCK.rmdir()
    except OSError:
        pass


def request(url, wav):
    """Koe's request: audio_ctx 0 (the whole window), temperature 0, text response."""
    fields = [('response_format', 'text'), ('prompt', PROMPT), ('temperature', '0.0'), ('audio_ctx', '0')]
    b = uuid.uuid4().hex
    body = b''.join(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode() for k, v in fields)
    body += (f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\n'
             'Content-Type: audio/wav\r\n\r\n').encode() + wav.read_bytes() + f'\r\n--{b}--\r\n'.encode()
    req = urllib.request.Request(url + '/inference', data=body,
                                 headers={'Content-Type': f'multipart/form-data; boundary={b}'})
    t = time.perf_counter()
    with NETWORK.open(req, timeout=300) as r:
        r.read()  # Discarded: only the time leaves this function.
    return (time.perf_counter() - t) * 1000


def run(url, clips, reps, label):
    request(url, clips[LENGTHS[0]])  # Warm-up, excluded.
    rows, loads = [], []
    for sec in LENGTHS:
        ms = []
        for _ in range(reps):
            loads.append(os.getloadavg()[0])
            ms.append(request(url, clips[sec]))
        ms.sort()
        rows.append((sec, statistics.median(ms), ms[min(len(ms) - 1, math.ceil(len(ms) * .9) - 1)]))
    print(f'\n## {label}  load1 {min(loads):.1f}-{max(loads):.1f}')
    print('| audio (s) | whisper median (ms) | whisper p90 (ms) | total est. median (ms) |')
    print('|---:|---:|---:|---:|')
    for sec, med, p90 in rows:
        print(f'| {sec} | {med:.0f} | {p90:.0f} | {TAIL_MS + med + PASTE_MS:.0f} |')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--own', action='store_true', help='start a separate whisper-server instead of borrowing Koe\'s')
    p.add_argument('--url', help='whisper-server to use (default: the running Koe\'s)')
    p.add_argument('--model', type=Path, default=KOE_DATA / 'models/ggml-large-v3-turbo.bin')
    p.add_argument('--reps', type=int, default=5)
    p.add_argument('--stress', type=int, default=0, metavar='N',
                   help='after the idle run, repeat with N busy CPU processes (0 = skip)')
    a = p.parse_args()

    v = voice()
    if not v:
        sys.exit('no Japanese voice for say')
    m = machine()
    print('# Koe paste latency bench')
    print(' '.join(f'{k}={val}' for k, val in m.items()))
    proc = None
    with tempfile.TemporaryDirectory() as tmp:
        clips = synth(Path(tmp), v)
        audio = hashlib.sha256(b''.join(clips[s].read_bytes() for s in LENGTHS)).hexdigest()[:12]
        print(f'voice={v} audio_sha={audio} reps={a.reps} server={"own" if a.own else "koe"}')
        try:
            if a.own:
                proc, url = start_server(a.model)
            else:
                url = a.url or running_server()
                if not url:
                    sys.exit('Koe whisper-server not found; start Koe or use --own')
            run(url, clips, a.reps, 'as is')
            if a.stress:
                # Separate interpreters, so this also works when the script is piped to python3 -.
                workers = [subprocess.Popen([sys.executable, '-c', 'while True: pass']) for _ in range(a.stress)]
                try:
                    time.sleep(5)
                    run(url, clips, a.reps, f'stress {a.stress} busy processes')
                finally:
                    for w in workers:
                        w.terminate()
                        w.wait()
        finally:
            stop_server(proc) if a.own else None
    print(f'\nfixed: tail {TAIL_MS} ms (Koe records 0.25 s after release), paste ~{PASTE_MS} ms')


if __name__ == '__main__':
    main()
