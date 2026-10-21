#!/usr/bin/env python3
"""A resident helper for asr_bench.py (#180): Parakeet-ja (NeMo TDT-CTC 0.6B, int8,
CTC head, greedy) through sherpa-onnx on the CPU, like Koe for Windows. Reads one
WAV path per line on stdin and prints {"text": ..., "seconds": ...} per line.
Run with the venv python that has asr_requirements.txt installed:

    sherpa_cli.py <model dir> [threads]
"""
import json
from pathlib import Path
import sys
import time
import wave

import numpy as np
import sherpa_onnx


def main():
    model = Path(sys.argv[1])
    threads = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    rec = sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
        model=str(model / 'model.int8.onnx'), tokens=str(model / 'tokens.txt'),
        num_threads=threads, decoding_method='greedy_search')
    for line in sys.stdin:
        started = time.perf_counter()
        with wave.open(line.strip(), 'rb') as w:
            pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
            rate = w.getframerate()
        stream = rec.create_stream()
        stream.accept_waveform(rate, pcm)
        rec.decode_stream(stream)
        print(json.dumps({'text': stream.result.text, 'seconds': time.perf_counter() - started}), flush=True)


if __name__ == '__main__':
    main()
