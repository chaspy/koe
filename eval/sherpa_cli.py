#!/usr/bin/env python3
"""A resident helper for asr_bench.py (#180): a sherpa-onnx offline recognizer. Reads one
WAV path per line on stdin (optionally followed by a tab and comma-separated hotwords, for
models that take them) and prints {"text": ..., "seconds": ...} per line.
Run with the venv python that has asr_requirements.txt installed:

    sherpa_cli.py <model dir> [threads]                       # Parakeet-ja (NeMo CTC), as before
    sherpa_cli.py <kind> <model dir> [threads] [provider]

kind: nemo_ctc (Parakeet-ja: TDT-CTC 0.6B int8, CTC head), moonshine (Moonshine v2 .ort),
qwen3 (Qwen3-ASR, takes hotwords), transducer (ReazonSpeech zipformer). All greedy.
provider: cpu (default) or coreml (ONNX Runtime's Core ML execution provider).
"""
import json
from pathlib import Path
import sys
import time
import wave

import numpy as np
import sherpa_onnx

KINDS = ('nemo_ctc', 'moonshine', 'qwen3', 'transducer')


def build(kind, model, threads, provider, hotwords=''):
    common = {'num_threads': threads, 'provider': provider, 'decoding_method': 'greedy_search'}
    if kind == 'nemo_ctc':
        return sherpa_onnx.OfflineRecognizer.from_nemo_ctc(
            model=str(model / 'model.int8.onnx'), tokens=str(model / 'tokens.txt'), **common)
    if kind == 'moonshine':
        return sherpa_onnx.OfflineRecognizer.from_moonshine_v2(
            encoder=str(model / 'encoder_model.ort'), decoder=str(model / 'decoder_model_merged.ort'),
            tokens=str(model / 'tokens.txt'), **common)
    if kind == 'qwen3':
        return sherpa_onnx.OfflineRecognizer.from_qwen3_asr(
            conv_frontend=str(model / 'conv_frontend.onnx'), encoder=str(model / 'encoder.int8.onnx'),
            decoder=str(model / 'decoder.int8.onnx'), tokenizer=str(model / 'tokenizer'),
            hotwords=hotwords, **common)
    if kind == 'transducer':
        return sherpa_onnx.OfflineRecognizer.from_transducer(
            encoder=str(model / 'encoder-epoch-99-avg-1.int8.onnx'),
            decoder=str(model / 'decoder-epoch-99-avg-1.onnx'),
            joiner=str(model / 'joiner-epoch-99-avg-1.int8.onnx'),
            tokens=str(model / 'tokens.txt'), **common)
    raise SystemExit(f'unknown kind {kind}; one of {", ".join(KINDS)}')


def main():
    args = sys.argv[1:]
    kind = args.pop(0) if args and args[0] in KINDS else 'nemo_ctc'
    model = Path(args[0])
    threads = int(args[1]) if len(args) > 1 else 4
    provider = args[2] if len(args) > 2 else 'cpu'
    hotwords = None
    rec = None
    for line in sys.stdin:
        path, _, hints = line.rstrip('\n').partition('\t')
        # hotwords are fixed when the recognizer is built: rebuild only when they change
        # (once per condition), and leave that time out of the measured seconds
        if rec is None or (kind == 'qwen3' and hints != hotwords):
            hotwords = hints
            rec = build(kind, model, threads, provider, hints.replace('\t', ',') if kind == 'qwen3' else '')
        started = time.perf_counter()
        with wave.open(path, 'rb') as w:
            pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
            rate = w.getframerate()
        stream = rec.create_stream()
        stream.accept_waveform(rate, pcm)
        rec.decode_stream(stream)
        print(json.dumps({'text': stream.result.text, 'seconds': time.perf_counter() - started}), flush=True)


if __name__ == '__main__':
    main()
