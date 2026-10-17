# Third-party notices (Koe for Windows)

Koe for Windows ships or downloads the following. Koe itself is MIT (see the repository's README).

## Shipped in the zip

| Files | Project | License |
|---|---|---|
| `whisper-server.exe`, `whisper-server-vulkan.exe`, `whisper.dll`, `ggml*.dll`, `parakeet.dll` | [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (ggml-org) | MIT |
| `SDL2.dll` (in the whisper.cpp release) | [SDL](https://www.libsdl.org/) | zlib |
| `sherpa-onnx-c-api.dll` | [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) (k2-fsa) | [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0) |
| `onnxruntime.dll`, `onnxruntime_providers_shared.dll` | [ONNX Runtime](https://github.com/microsoft/onnxruntime) (Microsoft) | MIT |

sherpa-onnx: Copyright (c) k2-fsa and its contributors. Licensed under the Apache License, Version 2.0; you may not use these files except in compliance with the License. You may obtain a copy of the License at https://www.apache.org/licenses/LICENSE-2.0. Distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND. Koe ships the unmodified DLL from the sherpa-onnx release (win-x64, shared, MT, Release, no TTS).

## Downloaded on first use

| Model | When | License |
|---|---|---|
| whisper models (`ggml-*.bin`) from [ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp), converted from OpenAI Whisper | engine `whisper` (default) | MIT |
| **Parakeet-ja**: `sherpa-onnx-nemo-parakeet-tdt_ctc-0.6b-ja-35000-int8` | only with `"engine": "parakeet"` in config.json | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |

Parakeet-ja attribution: the model is [nvidia/parakeet-tdt_ctc-0.6b-ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) by NVIDIA, licensed under CC BY 4.0. Changes: it was converted to ONNX and quantized to int8 by the sherpa-onnx project ([release `asr-models`](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)); Koe uses that file as is (only the CTC model and tokens are unpacked).
