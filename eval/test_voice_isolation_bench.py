"""Synthetic numbers only: no speech, noise download, helper or server."""
import array
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import voice_isolation_bench as vib


def tone(n, amp=3000, offset=0):
    return array.array('h', (int(amp * math.sin((i + offset) * 0.3)) or 1 for i in range(n)))


class ZeroRunsTest(unittest.TestCase):
    def test_counts_runs_inside_speech_only(self):
        gap = array.array('h', [0] * 1600)  # 100 ms at 16 kHz
        self.assertEqual(vib.zero_runs(gap + tone(1600) + gap), (0, 0.0))  # leading / trailing silence
        runs, ratio = vib.zero_runs(tone(1600) + gap + tone(1600))
        self.assertEqual(runs, 1)
        self.assertAlmostEqual(ratio, 1600 / 4800)
        short = array.array('h', [0] * 1599)
        self.assertEqual(vib.zero_runs(tone(1600) + short + tone(1600))[0], 0)
        self.assertEqual(vib.zero_runs(array.array('h', [0] * 100)), (0, 0.0))


class MixTest(unittest.TestCase):
    def test_snr(self):
        speech, noise = tone(16000, 4000), tone(16000, 1000, offset=7)
        for snr in (10, 15, 20):
            mixed = vib.mix(speech, noise, snr)
            added = array.array('h', (m - s for m, s in zip(mixed, speech)))
            self.assertAlmostEqual(20 * math.log10(vib.rms(speech) / vib.rms(added)), snr, delta=0.1)

    def test_clipped_to_16_bit(self):
        loud = array.array('h', [30000] * 100)
        self.assertLessEqual(max(vib.mix(loud, loud, -20)), 32767)

    def test_noise_segment_is_fixed_per_key(self):
        noise = tone(50000)
        a = vib.noise_segment(noise, 1000, 'BASIC5000_0001clean')
        self.assertEqual(a, vib.noise_segment(noise, 1000, 'BASIC5000_0001clean'))
        self.assertEqual(len(a), 1000)
        with self.assertRaises(ValueError):
            vib.noise_segment(tone(10), 11, 'x')


class PairedCITest(unittest.TestCase):
    def test_no_difference_and_clear_difference(self):
        same = [(1, 10)] * 50
        d, lo, hi = vib.paired_ci(same, same)
        self.assertEqual((d, lo, hi), (0.0, 0.0, 0.0))
        worse = [(3, 10)] * 50
        d, lo, hi = vib.paired_ci(same, worse)
        self.assertAlmostEqual(d, 0.2)
        self.assertGreater(lo, 0)

    def test_fixed_seed(self):
        a = [(i % 3, 10) for i in range(40)]
        b = [(i % 4, 10) for i in range(40)]
        self.assertEqual(vib.paired_ci(a, b), vib.paired_ci(a, b))


class ConditionsTest(unittest.TestCase):
    def test_clean_first_then_each_snr(self):
        labels = [c[0] for c in vib.conditions(['OOFFICE'])]
        self.assertEqual(labels, ['clean', 'OOFFICE_20dB', 'OOFFICE_15dB', 'OOFFICE_10dB'])

    def test_table_has_numbers_only(self):
        r = {'clips': 2, 'terms': 1, 'conditions': {'clean': {
            'off': {'cer': 0.05, 'terms_right': 1, 'zero_run_utterances': 0},
            'on': {'cer': 0.08, 'terms_right': 0, 'zero_run_utterances': 2},
            'cer_diff': {'on_minus_off': 0.03, 'ci95': [0.01, 0.05]}}}}
        t = vib.table(r)
        self.assertIn('| clean | on | 8.0% | +3.0 pt（+1.0〜+5.0） | 0/1 | 2/3 |', t)


if __name__ == '__main__':
    unittest.main()
