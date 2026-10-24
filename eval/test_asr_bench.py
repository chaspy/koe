"""asr_bench helpers on synthetic data only (no model, no network)."""

import unittest

import asr_bench as a
import audio_ctx_bench as ab


class AsrBenchTests(unittest.TestCase):
    def test_term_items_are_deterministic_and_have_kana_or_latin(self):
        entries = [(t, []) for t in ['プルリク', '遅延', 'GitHub', 'マージ', '設定', 'k8s', 'デプロイ']]
        items = a.term_items(entries)
        self.assertEqual(items, a.term_items(entries))
        self.assertEqual([t for t, _ in items], ['プルリク', 'GitHub', 'マージ', 'k8s', 'デプロイ'])
        for (term, sentence), template in zip(items, a.TEMPLATES * 3):
            self.assertEqual(sentence, template.format(term))

    def test_fold_and_raw_chars(self):
        self.assertEqual(a.fold('Ｇｉｔ Hub'), 'github')
        self.assertIn(a.fold('GitHub'), a.fold('ギットの GITHUB に上げる'))
        self.assertEqual(a.raw_chars(' 猫 が、 いる。\n'), '猫が、いる。')

    def test_hint_line_keeps_each_term_once_in_order(self):
        entries = [('GitHub', ['ギットハブ']), ('マージ', []), ('GitHub', ['ぎっとはぶ']), ('a\tb', [])]
        self.assertEqual(a.hint_line(entries), 'GitHub\tマージ')

    def test_speech_engines_take_hints(self):
        self.assertTrue(a.SpeechAnalyzerEngine.hints and a.DictationEngine.hints)
        self.assertFalse(a.ParakeetEngine().hints)
        self.assertEqual((a.SpeechAnalyzerEngine.module, a.DictationEngine.module), ('speech', 'dictation'))

    def test_sherpa_engines(self):
        names = ['parakeet-ja-sherpa-cpu', 'parakeet-ja-sherpa-coreml', 'moonshine-tiny-ja-sherpa-cpu',
                 'qwen3-asr-0.6b-sherpa-cpu', 'reazonspeech-zipformer-sherpa-cpu']
        engines = {n: a.ENGINES[n]() for n in names}
        for n, e in engines.items():
            self.assertEqual(e.name, n)
            self.assertRegex(e.sha256, '^[0-9a-f]{64}$')
            self.assertFalse(e.prompts)
        # only Qwen3-ASR takes hotwords; the Core ML variant differs only in the provider
        self.assertEqual([n for n, e in engines.items() if e.hints], ['qwen3-asr-0.6b-sherpa-cpu'])
        self.assertEqual(engines['parakeet-ja-sherpa-coreml'].provider, 'coreml')
        self.assertEqual(engines['parakeet-ja-sherpa-cpu'].archive, engines['parakeet-ja-sherpa-coreml'].archive)
        self.assertIn('non-commercial', engines['moonshine-tiny-ja-sherpa-cpu'].licence)

    def test_every_engine_says_whether_it_takes_hints(self):
        for name, make in a.ENGINES.items():
            self.assertIn(make().hints, (True, False), name)

    def test_p90(self):
        self.assertEqual(a.p90([1]), 1)
        self.assertEqual(a.p90(list(range(1, 11))), 9)

    def test_models_are_pinned(self):
        for m in (a.TURBO, a.KOTOBA):
            self.assertEqual(len(m.sha256), 64)
            self.assertEqual(len(m.revision), 40)
            self.assertTrue(m.licence)

    def test_table_has_every_bucket(self):
        bucket = {'n': 1, 'median': 0.5, 'p90': 0.6, 'cer': 0.1, 'empty': 0}
        cond = {'buckets': {label: bucket for label, _, _ in ab.BUCKETS}, 'err_raw': 1, 'len_raw': 10,
                'err_norm': 1, 'len_norm': 20, 'terms': {'n': 2, 'right': 1, 'median': 0.4}}
        text = a.table([{'engine': 'x', 'model_mb': 1, 'licence': 'MIT', 'peak_rss_mb': 2,
                         'conditions': {'base': cond}}])
        self.assertIn('| x | base | 10.00 | 5.00 | 1/2 | 0.500 | 0.600 | 0.500 | 0.500 | 2 | 1 | MIT |', text)
        for label, _, _ in ab.BUCKETS:
            self.assertIn(label, text)
        self.assertIn('10.0 (0)', text)
        failed = a.table([{'engine': 'y', 'error': 'RuntimeError', 'conditions': {}}])
        self.assertIn('y: not measured (RuntimeError)', failed)



class WhisperKitTest(unittest.TestCase):
    def test_engines_and_manifest(self):
        import json
        m = json.loads(a.WhisperKitEngine.manifest.read_text())
        self.assertRegex(m['revision'], '^[0-9a-f]{40}$')
        for name in ('whisperkit-turbo', 'whisperkit-turbo-626mb'):
            e = a.ENGINES[name]()
            self.assertTrue(e.prompts)
            self.assertFalse(e.hints)
            files = m['models'][e.model]
            self.assertTrue(files)
            for rel, sha in files.items():
                self.assertRegex(sha, '^[0-9a-f]{64}$', rel)
            self.assertIn('AudioEncoder.mlmodelc/model.mil', files)

class NoisyVariantsTest(unittest.TestCase):
    def test_pack_and_hints_per_snr_with_noise_mixed_in(self):
        import array
        import math
        import tempfile
        from pathlib import Path
        from unittest import mock
        import voice_isolation_bench as vib

        def tone(n, amp):
            return array.array('h', (int(amp * math.sin(i * 0.3)) or 1 for i in range(n)))
        with tempfile.TemporaryDirectory() as d:
            cache = Path(d)
            twav = cache / 'abc.wav'
            a.ab.write_wav(twav, tone(8000, 3000))
            sets = {'<5 s': [(tone(8000, 3000), 'ref')]}
            terms = ([('GitHub', 'GitHubの設定')], [twav])
            entries = [('GitHub', [])]
            with mock.patch.object(vib, 'fetch_noise', return_value=tone(40000, 500)):
                hinted = a.noisy_variants(a.ENGINES['qwen3-asr-0.6b-sherpa-cpu'](), cache, sets, terms, entries, 'OOFFICE', [20, 10])
                plain = a.noisy_variants(a.ENGINES['whisper-turbo-metal'](), cache, sets, terms, entries, 'OOFFICE', [15])
            self.assertEqual([v[0] for v in hinted], ['pack@OOFFICE_20dB', 'hints@OOFFICE_20dB', 'pack@OOFFICE_10dB', 'hints@OOFFICE_10dB'])
            name, noisy, wavs, prompt, pack = plain[0]
            self.assertEqual(name, 'pack@OOFFICE_15dB')
            self.assertEqual(prompt, a.pb.pack_prompt(entries))  # whisper keeps the pack prompt
            self.assertEqual(hinted[0][3], '')                    # no prompt: autocorrect only
            self.assertNotEqual(noisy['<5 s'][0][0], sets['<5 s'][0][0])  # noise was added
            self.assertEqual(noisy['<5 s'][0][1], 'ref')
            self.assertTrue(wavs[0].exists() and wavs[0] != twav)


if __name__ == '__main__':
    unittest.main()
