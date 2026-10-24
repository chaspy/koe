// Imported from koe-audio-core (commit 00fe10f). Copyright (c) chaspy.
// Loudness and silence measurement for Koe (https://github.com/chaspy/koe).
#pragma once

#include <algorithm>
#include <cmath>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace koe {

struct Quality {
  bool valid = false;
  double level_db = 0;
  double noise_db = 0;
  double snr_db = 0;
  double speech_s = 0;
  double clip_ratio = 0;
  double brightness = 0;
};

inline constexpr int kWindowMs = 30;
inline constexpr double kSpeechFloor = 50.0;     // about -56 dBFS
inline constexpr double kSpeechOverNoise = 3.16; // 10 dB over the background
inline constexpr double kQuietDb = -45.0;
inline constexpr double kQuietMinSpeech = 0.3;

template <class T>
concept Sample = std::same_as<T, int16_t> || std::same_as<T, float>;

// Value on the int16 scale. Float input is clamped to [-1, 1]; NaN becomes 0
// so sorting and sums stay well defined.
template <Sample T>
constexpr double to_i16_scale(T v) {
  if constexpr (std::same_as<T, float>) {
    if (std::isnan(v)) return 0.0;
    return static_cast<double>(std::clamp(v, -1.0f, 1.0f)) * 32768.0;
  } else {
    return static_cast<double>(v);
  }
}

inline double round_to(double x, double scale) { return std::round(x * scale) / scale; }
inline double db(double x) { return round_to(20 * std::log10(x / 32768), 10); }

template <Sample T>
Quality measure(std::span<const T> pcm, int sample_rate = 16000) {
  const std::size_t win = static_cast<std::size_t>(sample_rate) * kWindowMs / 1000;
  if (win == 0 || pcm.size() <= win * 4) return {};

  std::vector<double> rms;
  rms.reserve(pcm.size() / win);
  for (std::size_t i = 0; i + win <= pcm.size(); i += win) {
    double sum = 0;
    for (std::size_t j = i; j < i + win; ++j) {
      const double v = to_i16_scale(pcm[j]);
      sum += v * v;
    }
    rms.push_back(std::sqrt(sum / static_cast<double>(win)));
  }

  std::vector<double> sorted = rms;
  std::ranges::sort(sorted);
  const double noise = std::max(sorted[sorted.size() / 10], 1.0);
  const double gate = std::max(noise * kSpeechOverNoise, kSpeechFloor);

  double voiced_sum = 0;
  std::size_t voiced = 0;
  for (double r : rms) {
    if (r > gate) {
      voiced_sum += r;
      ++voiced;
    }
  }
  if (voiced == 0) return {};
  const double speech = voiced_sum / static_cast<double>(voiced);

  std::size_t clipped = 0;
  for (T s : pcm) clipped += std::abs(to_i16_scale(s)) >= 32000;
  double e = 0, d = 0;
  for (std::size_t k = 1; k < pcm.size(); ++k) {
    const double a = to_i16_scale(pcm[k]), b = to_i16_scale(pcm[k - 1]);
    e += a * a;
    d += (a - b) * (a - b);
  }

  Quality q;
  q.valid = true;
  q.level_db = db(speech);
  q.noise_db = db(noise);
  q.snr_db = round_to(20 * std::log10(speech / noise), 10);
  q.speech_s = round_to(static_cast<double>(voiced * win) / sample_rate, 100);
  q.clip_ratio = round_to(static_cast<double>(clipped) / static_cast<double>(pcm.size()), 10000);
  q.brightness = e > 0 ? round_to(d / e, 1000) : 0;
  return q;
}

inline bool too_quiet(const Quality &q) {
  return q.valid && q.level_db < kQuietDb && q.speech_s >= kQuietMinSpeech;
}

} // namespace koe
