"""Public benchmark metric and request regression tests (synthetic data only)."""

import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import wave

import public_bench as pb


class PublicBenchTests(unittest.TestCase):
    def test_subset_is_fixed(self):
        self.assertEqual(len(pb.IDS), 200)
        self.assertEqual(pb.IDS[0], 'BASIC5000_0001')
        self.assertEqual(pb.IDS[-1], 'BASIC5000_0200')
        self.assertEqual(len(set(pb.IDS)), 200)

    def test_normalization(self):
        self.assertEqual(pb.normalize(' Ａ、猫。「犬」!?\n—'), 'A猫犬')
        self.assertNotEqual(pb.normalize('はし'), pb.normalize('橋'))

    def test_corpus_cer_and_nearest_rank_p95(self):
        rows = [(1, 2, 1, False), (0, 8, 3, True)]
        self.assertEqual(pb.metrics(rows), (.1, 2, 3, 1))
        self.assertEqual(pb.metrics([(0, 1, i, False) for i in range(1, 21)])[2], 19)

    def test_repetition_thresholds(self):
        for text in ('同じ文章。同じ文章。同じ文章。', '単語、' * 5, 'カタカナ' * 6):
            self.assertTrue(pb.repetitive(text))
        for text in ('同じ文章。同じ文章。', '単語、' * 4, 'カタカナ' * 5, '1000000000000000'):
            self.assertFalse(pb.repetitive(text))

    def test_pack_budget_and_autocorrect(self):
        self.assertEqual(pb.pack_prompt([]), pb.BASE_PROMPT)
        entries = [('A' * 120, []), ('B', []), ('A' * 120, [])]
        self.assertEqual(pb.pack_prompt(entries), 'A' * 120 + '。' + pb.BASE_PROMPT)
        entries = [('マージ', ['~マジ', 'マジ>(する)', 'マージュ'])]
        self.assertEqual(pb._autocorrect('マジでマジするマージュ', entries), 'マジでマージするマージ')

    def test_audio_window(self):
        self.assertEqual([pb.audio_ctx(n) for n in (2, 20, 29, 30)], [768, 1164, 1500, 0])

    def test_request_profiles(self):
        with tempfile.TemporaryDirectory() as directory:
            wav = Path(directory) / 'synthetic.wav'
            with wave.open(str(wav), 'wb') as audio:
                audio.setnchannels(1)
                audio.setsampwidth(2)
                audio.setframerate(16000)
                audio.writeframes(b'\0\0' * 16000)
            for windows in (False, True):
                with patch.object(pb.NETWORK, 'open', return_value=io.BytesIO(b'test')) as request:
                    text, elapsed = pb.transcribe('http://127.0.0.1:1234', wav, 'synthetic', windows)
                body = request.call_args.args[0].data
                self.assertEqual(text, 'test')
                self.assertGreaterEqual(elapsed, 0)
                self.assertIn(b'name="audio_ctx"\r\n\r\n768', body)
                self.assertEqual(b'temperature_inc' in body, windows)
                self.assertIn(b'name="prompt"\r\n\r\nsynthetic', body)

    def test_server_cleanup_on_startup_failure(self):
        from unittest.mock import MagicMock
        process = MagicMock()
        process.poll.return_value = 1
        with patch.object(pb.subprocess, 'Popen', return_value=process):
            with self.assertRaises(RuntimeError):
                with pb.server(Path('/synthetic/server'), Path('/synthetic/model'), False):
                    self.fail('An exited server must not become ready')
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=10)

    def test_range_rejects_full_download(self):
        response = io.BytesIO(b'unexpected')
        response.status = 200
        response.headers = {}
        with patch.object(pb.NETWORK, 'open', return_value=response):
            with self.assertRaises(ValueError):
                pb.RemoteZip().read(10)

    def test_range_validates_version_and_offset(self):
        response = io.BytesIO(b'abc')
        response.status = 206
        response.headers = {'ETag': pb.DATA_ETAG,
                            'Content-Range': f'bytes 10-12/{pb.DATA_SIZE}'}
        with patch.object(pb.NETWORK, 'open', return_value=response):
            archive = pb.RemoteZip()
            archive.seek(10)
            self.assertEqual(archive.read(3), b'abc')
            self.assertEqual(archive.tell(), 13)


if __name__ == '__main__':
    unittest.main()
