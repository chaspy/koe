"""audio_ctx_bench helpers on synthetic data only."""

import array
from pathlib import Path
import tempfile
import unittest
import wave

import audio_ctx_bench as b


def clip(path, seconds, loud=1000):
    pcm = array.array('h', [0] * 8000 + [loud] * int(seconds * b.RATE) + [0] * 8000)
    with wave.open(str(path), 'wb') as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(b.RATE)
        audio.writeframes(pcm.tobytes())
    return path


class AudioCtxBenchTests(unittest.TestCase):
    def test_trim_keeps_padding(self):
        with tempfile.TemporaryDirectory() as tmp:
            pcm = b.trimmed(clip(Path(tmp) / 'a.wav', 2))
        self.assertEqual(len(pcm), 2 * b.RATE + 2 * b.PAD - 1)

    def test_buckets_are_deterministic_and_in_range(self):
        with tempfile.TemporaryDirectory() as tmp:
            clips = [(clip(Path(tmp) / f'{i}.wav', 1 + i % 4), f'r{i}') for i in range(40)]
            first, second = b.utterances(clips), b.utterances(clips)
        self.assertEqual({k: [r for _, r in v] for k, v in first.items()},
                         {k: [r for _, r in v] for k, v in second.items()})
        for label, low, high in b.BUCKETS:
            if label == '<5 s':
                self.assertEqual(len(first[label]), 40)
            else:
                self.assertTrue(0 < len(first[label]) <= b.PER_BUCKET, label)
            for pcm, _ in first[label]:
                self.assertTrue(low <= len(pcm) / b.RATE < high, label)

    def test_foreign_script(self):
        for text in ('プルリクをマージ', 'GitHub の PR', 'café', 'ｶﾀｶﾅ', '①、「」'):
            self.assertFalse(b.foreign_script(text), text)
        for text in ('회의', 'Привет', 'ทดสอบ'):
            self.assertTrue(b.foreign_script(text), text)


if __name__ == '__main__':
    unittest.main()
