// Checks core.sherpaRecognizerConfig (windows/core/engine.go) against
// sherpa-onnx's c-api.h for 64-bit Windows. Compile only; nothing runs:
//
//   tar xjf sherpa-onnx-<SherpaVersion>-win-x64-shared-MT-Release-no-tts.tar.bz2 '*/include/*'
//   clang -target x86_64-pc-windows-msvc -ffreestanding -fsyntax-only \
//     -I sherpa-onnx-<SherpaVersion>-win-x64-shared-MT-Release-no-tts/include tools/sherpa-offsets.c
//
// If an assertion fails, the C struct changed: update the padding in
// engine.go and the numbers here and in TestSherpaRecognizerConfigLayout.
#include <stddef.h>
#include <stdint.h>

#include "sherpa-onnx/c-api/c-api.h"

#define AT(field, offset) \
  _Static_assert(offsetof(SherpaOnnxOfflineRecognizerConfig, field) == offset, #field);

_Static_assert(sizeof(SherpaOnnxOfflineRecognizerConfig) == 608, "size");
AT(feat_config.sample_rate, 0)
AT(feat_config.feature_dim, 4)
AT(model_config.nemo_ctc.model, 40)
AT(model_config.tokens, 104)
AT(model_config.num_threads, 112)
AT(model_config.debug, 116)
AT(model_config.provider, 120)
AT(decoding_method, 528)
