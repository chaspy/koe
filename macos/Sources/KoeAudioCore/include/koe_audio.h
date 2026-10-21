/* Imported from koe-audio-core (commit fdd2814). Copyright (c) chaspy. */
/* koe_audio.h - C API for koe's loudness / silence judgement.
 *
 * Ownership: the caller owns every buffer. The library only reads `pcm` during
 * the call and never keeps or returns allocated memory.
 * Samples are mono. int16 is full scale +-32768; float is full scale +-1.0.
 */
#ifndef KOE_AUDIO_H
#define KOE_AUDIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define KOE_OK 0
#define KOE_ERR_INVALID_ARG (-1) /* NULL pointer, bad sample rate */
#define KOE_ERR_INTERNAL (-2)    /* allocation failure etc. */

typedef struct koe_quality {
  int valid;          /* 0: too short or no voiced window; other fields are 0 */
  double level_db;    /* mean RMS of voiced windows, dBFS */
  double noise_db;    /* background (lowest 10% window), dBFS */
  double snr_db;      /* level - noise */
  double speech_s;    /* voiced duration, seconds */
  double clip_ratio;  /* share of samples at/near full scale */
  double brightness;  /* high-frequency energy ratio (small = muffled) */
} koe_quality;

/* Fills *out. Returns KOE_OK even when no voice was found (out->valid == 0).
 * pcm may be NULL only when len == 0. sample_rate is in Hz (8000..192000). */
int koe_measure_i16(const int16_t *pcm, size_t len, int sample_rate, koe_quality *out);
int koe_measure_f32(const float *pcm, size_t len, int sample_rate, koe_quality *out);

/* 1 when the voice was recorded too quietly (< -45 dB for >= 0.3 s), else 0. */
int koe_too_quiet(const koe_quality *q);

#ifdef __cplusplus
}
#endif

#endif
