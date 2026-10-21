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
        self.assertFalse(a.ParakeetEngine.hints)
        self.assertEqual((a.SpeechAnalyzerEngine.module, a.DictationEngine.module), ('speech', 'dictation'))

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


if __name__ == '__main__':
    unittest.main()
