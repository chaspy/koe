"""VAD benchmark regression tests (synthetic signals only, no network, no model)."""

import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

import vad_bench as vb


def tone(seconds, amplitude=8000):
    t = np.arange(int(seconds * vb.RATE)) / vb.RATE
    return (amplitude * np.sin(2 * np.pi * 220 * t)).astype('<i2')


def quiet(seconds):
    return np.zeros(int(seconds * vb.RATE), '<i2')


class FakeVAD:
    def __init__(self, probabilities):
        self.probabilities_ = probabilities

    def probabilities(self, pcm):
        return self.probabilities_


class VadBenchTests(unittest.TestCase):
    def test_speech_span_hysteresis_and_min_speech(self):
        frame = vb.CHUNK / vb.RATE
        # 10 silent frames, 20 speech frames, 2 ambiguous frames, 20 silent frames.
        probabilities = [0.1] * 10 + [0.9] * 20 + [0.4] * 2 + [0.1] * 20
        start, end = vb.speech_span(probabilities)
        self.assertAlmostEqual(start, 10 * frame)
        self.assertAlmostEqual(end, 32 * frame)  # Ambiguous frames stay inside speech.
        self.assertIsNone(vb.speech_span([0.1] * 50))
        self.assertIsNone(vb.speech_span([0.1] * 10 + [0.9] * 3 + [0.1] * 10))  # 96 ms < 250 ms
        self.assertEqual(vb.speech_span([0.9] * 10), (0.0, 10 * frame))  # Speech until the end.

    def test_koe_trim_matches_app_padding(self):
        pcm = np.concatenate([quiet(1.0), tone(1.0), quiet(1.0)])
        start, end = vb.koe_trim(pcm)
        # Windows step from the start (first loud) and from the end (last loud), as in the app.
        first = vb.RATE // vb.KOE_WINDOW * vb.KOE_WINDOW
        last = (2 * vb.RATE - 1) // vb.KOE_WINDOW * vb.KOE_WINDOW
        self.assertEqual(start, first - int(vb.RATE * 0.25))
        self.assertEqual(end, last + vb.KOE_WINDOW + int(vb.RATE * 0.3))
        self.assertIsNone(vb.koe_trim(quiet(2.0)))
        self.assertIsNone(vb.koe_trim(tone(2.0, amplitude=300)))  # RMS below 330.
        self.assertEqual(vb.koe_trim(tone(1.0)), (0, vb.RATE))

    def test_vad_trim_pads_and_clamps(self):
        pcm = quiet(3.0)
        frame = vb.CHUNK / vb.RATE
        vad = FakeVAD([0.0] * 30 + [1.0] * 30 + [0.0] * 33)
        self.assertEqual(vb.vad_trim(vad, pcm, 0.25, 0.3),
                         (int((30 * frame - 0.25) * vb.RATE), int((60 * frame + 0.3) * vb.RATE)))
        self.assertEqual(vb.vad_trim(vad, pcm, 5.0, 5.0), (0, len(pcm)))
        self.assertIsNone(vb.vad_trim(FakeVAD([0.0] * 93), pcm, 0.25, 0.3))

    def test_synthetic_variants_are_deterministic(self):
        rng = np.random.default_rng(1)
        pcm = tone(1.0)
        self.assertIs(vb.synthesize(pcm, rng, 1.5, 2.5, None), pcm)
        padded = vb.synthesize(pcm, np.random.default_rng(1), 1.5, 2.5, -60.0)
        self.assertEqual(len(padded), int(5.0 * vb.RATE))
        self.assertEqual(padded.dtype, np.dtype('<i2'))
        np.testing.assert_array_equal(padded, vb.synthesize(pcm, np.random.default_rng(1), 1.5, 2.5, -60.0))
        floor = vb.noise(np.random.default_rng(2), 4 * vb.RATE, -38.0)
        self.assertAlmostEqual(np.sqrt(np.mean(floor ** 2)), 412, delta=10)
        clips = vb.silence_clips(np.random.default_rng(3))
        self.assertEqual(len(clips), len(vb.SILENCE_LEVELS) * vb.SILENCE_PER_LEVEL)
        self.assertTrue(all(vb.RATE <= len(c) <= 6 * vb.RATE for c in clips))

    def test_stock_phrase_removal(self):
        self.assertEqual(vb.remove_stock_phrases('テスト (音楽) 終わり。ご視聴ありがとうございました。'), 'テスト 終わり。')
        self.assertEqual(vb.remove_stock_phrases('[BLANK_AUDIO]'), '')

    def test_request_fields(self):
        data = vb.wav_bytes(tone(0.5))
        self.assertTrue(data.startswith(b'RIFF'))
        with patch.object(vb.pb.NETWORK, 'open', side_effect=lambda *a, **k: io.BytesIO(b'test')) as request:
            text, elapsed = vb.transcribe('http://127.0.0.1:1234', data, 'p', 768)
            body = request.call_args.args[0].data
            self.assertEqual(text, 'test')
            self.assertGreaterEqual(elapsed, 0)
            self.assertIn(b'name="audio_ctx"\r\n\r\n768', body)
            self.assertNotIn(b'temperature_inc', body)
            vb.transcribe('http://127.0.0.1:1234', data, '', 0, '0.2')
            self.assertIn(b'name="temperature_inc"\r\n\r\n0.2', request.call_args.args[0].data)
            self.assertNotIn(b'name="vad"', request.call_args.args[0].data)
            vb.transcribe('http://127.0.0.1:1234', data, 'p', 768, server_vad=True)
            body = request.call_args.args[0].data
            self.assertIn(b'name="vad"\r\n\r\ntrue', body)
            self.assertIn(b'name="vad_speech_pad_ms"\r\n\r\n250', body)

    def test_run_clip_skips_without_speech_and_drops_hallucinations(self):
        pcm = quiet(2.0)
        with patch.object(vb, 'transcribe') as transcribe:
            result = vb.run_clip('url', pcm, 'vad', FakeVAD([0.0] * 62))
            self.assertEqual(result[0], None)
            self.assertTrue(result[4])
            transcribe.assert_not_called()
            result = vb.run_clip('url', pcm, 'koe', None)
            self.assertTrue(result[4])
            transcribe.assert_not_called()
        voiced = np.concatenate([quiet(0.5), tone(2.0), quiet(0.5)])
        with patch.object(vb, 'transcribe', side_effect=[('ご視聴ありがとうございました', 0.1), ('', 0.1)]) as transcribe:
            result = vb.run_clip('url', voiced, 'koe', None)
            self.assertEqual(transcribe.call_count, 2)  # Retry without prompt, then drop.
            self.assertEqual(transcribe.call_args.args[2], '')
            self.assertIsNone(result[0])
            self.assertTrue(result[5])
            self.assertAlmostEqual(result[2], 0.2)
        with patch.object(vb, 'transcribe', return_value=('ご視聴ありがとうございました', 0.1)):
            self.assertEqual(vb.run_clip('url', voiced, 'raw', None)[0], 'ご視聴ありがとうございました')
        with patch.object(vb, 'transcribe', return_value=('はい', 0.1)) as transcribe:
            self.assertEqual(vb.run_clip('url', voiced, 'koe+server-vad', None)[0], 'はい')
            self.assertTrue(transcribe.call_args.kwargs['server_vad'])
            self.assertFalse(vb.run_clip('url', voiced, 'koe', None)[4])
            self.assertFalse(transcribe.call_args.kwargs['server_vad'])
            self.assertTrue(vb.run_clip('url', pcm, 'koe+server-vad', None)[4])  # Energy gate first.
        with patch.object(vb, 'transcribe', side_effect=[('はい (音楽)', 0.1), ('はい (音楽)', 0.3)]) as transcribe:
            result = vb.run_clip('url', voiced, 'koe', None)
            self.assertEqual(result[0], 'はい')
            self.assertEqual(transcribe.call_args.args[3], 0)  # Retry uses the whole window.

    def test_summary_counts(self):
        rows = [('こんにちは世界', 0.01, 0.3, 2.0, False, False), (None, 0.01, 0.0, 0.0, True, False),
                ('んにちは世', 0.02, 0.4, 2.0, False, False), (None, 0.01, 0.5, 2.0, False, True)]
        references = ['こんにちは世界', '', 'こんにちは世界', 'こんにちは世界']
        m = vb.summarize(rows, references)
        self.assertAlmostEqual(m['cer'], 9 / 21)
        self.assertEqual((m['skipped'], m['dropped'], m['pasted'], m['head'], m['tail']), (1, 1, 2, 2, 2))
        self.assertAlmostEqual(m['median'], 0.365)
        self.assertAlmostEqual(m['p95'], 0.51)
        self.assertAlmostEqual(m['sent'], 6.0)

    def test_fetch_verifies_checksum(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(vb.pb.NETWORK, 'open', return_value=io.BytesIO(b'not the model')):
                with self.assertRaises(ValueError):
                    vb.fetch(Path(directory), 'src/silero_vad/data/silero_vad.onnx', vb.VAD_SHA)
            self.assertFalse(list(Path(directory).glob('*.onnx')))


if __name__ == '__main__':
    unittest.main()
