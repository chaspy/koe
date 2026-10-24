// Imported from koe-audio-core (commit 00fe10f). Copyright (c) chaspy.
#include "koe_audio.h"

#include <exception>
#include <span>

#include "quality.hpp"

namespace {

template <koe::Sample T>
int measure_c(const T *pcm, size_t len, int sample_rate, koe_quality *out) {
  if (out == nullptr || (pcm == nullptr && len != 0) || sample_rate < 8000 || sample_rate > 192000)
    return KOE_ERR_INVALID_ARG;
  *out = koe_quality{};
  try {
    const koe::Quality q = koe::measure(std::span<const T>(pcm, len), sample_rate);
    out->valid = q.valid;
    out->level_db = q.level_db;
    out->noise_db = q.noise_db;
    out->snr_db = q.snr_db;
    out->speech_s = q.speech_s;
    out->clip_ratio = q.clip_ratio;
    out->brightness = q.brightness;
  } catch (...) {  // never let an exception cross the C boundary
    return KOE_ERR_INTERNAL;
  }
  return KOE_OK;
}

} // namespace

extern "C" {

int koe_audio_api_version(void) {
  return KOE_AUDIO_API_VERSION;
}

int koe_measure_i16(const int16_t *pcm, size_t len, int sample_rate, koe_quality *out) {
  return measure_c(pcm, len, sample_rate, out);
}

int koe_measure_f32(const float *pcm, size_t len, int sample_rate, koe_quality *out) {
  return measure_c(pcm, len, sample_rate, out);
}

int koe_too_quiet(const koe_quality *q) {
  return q != nullptr && q->valid && q->level_db < koe::kQuietDb && q->speech_s >= koe::kQuietMinSpeech;
}

}
