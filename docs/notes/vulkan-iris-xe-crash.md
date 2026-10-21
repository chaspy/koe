# Vulkan whisper-server crash on Intel Iris Xe (work note)

Report: on a tester's Iris Xe, whisper-server-vulkan.exe (whisper.cpp v1.9.2, built by whisper-vulkan.yml) exits 0xC0000409 after `GGML_ASSERT(prev != ggml_uncaught_exception)`. Koe falls back to the CPU build, which is kept as is.

## What the assert means (source, ggml/src/ggml.cpp)
A static initializer installs `ggml_uncaught_exception` as the C++ terminate handler and asserts the previous handler is not already that function. It fails only if that initializer runs a second time in the same process with the same function address. 0xC0000409 is MSVC's fast-fail from `abort()`. The GPU-less CI run of the same exe did not crash, so the second run seems tied to the device path (not confirmed). `GGML_NO_BACKTRACE=1` skips the initializer and should expose the underlying error.

## Reproduction attempt on CI
A temporary workflow `.github/workflows/vulkan-repro.yml` (push to `repro/**`; removed before merging, it stays in the history of pull request #107): the existing exe artifact, the LunarG Vulkan loader, a software ICD (SwiftShader from the runner's Chrome; Mesa lavapipe), small-q5_1, Koe's server arguments, assets/probe.wav posted twice; variants: default, `GGML_NO_BACKTRACE=1`, `-nfa`.

## Results (2026-10-16)

| run | what | outcome | billed |
|---|---|---|---:|
| 38847661501 | SwiftShader / lavapipe via `VK_DRIVER_FILES` | no Vulkan device ("no GPU found"): ggml-vulkan only takes integrated / discrete GPUs | 6 min |
| 38847962497 | + `GGML_VK_VISIBLE_DEVICES=0` | still none: `backends = 1`, the Vulkan backend did not register | 4 min |
| 38848217650 | + `VK_LOADER_DEBUG`, vulkaninfo | the loader ignores `VK_DRIVER_FILES` / `VK_ICD_FILENAMES` in an elevated process (the runner): "Found no drivers" | 2 min |
| 38848349192 | ICD registered in `HKLM\SOFTWARE\Khronos\Vulkan\Drivers`, small-q5_1, 3 variants | **SwiftShader: exit 0xC0000409 at model load** — "device Vulkan0 does not support 16-bit storage" → "exception during model load: Unsupported device" → "failed to initialize whisper context", then `vkDestroyFence: Invalid device` during teardown. No `GGML_ASSERT(prev != ggml_uncaught_exception)`. Same with `GGML_NO_BACKTRACE=1` and `-nfa`. **lavapipe: runs on Vulkan0** but small-q5_1 timed out (> 180 s per request on 2 cores) | 13 min |
| 38849357616 | lavapipe, base-q5_1, audio_ctx 384 | **no crash**: model load and two transcriptions on Vulkan0 (126 s, then 21 s), also with `GGML_NO_BACKTRACE=1` | 6 min |

Total 31 billed minutes ≈ $0.31 (Windows runner $0.010/min; cap $0.50).

## Conclusion
- The tester's crash (`GGML_ASSERT(prev != ggml_uncaught_exception)` then 0xC0000409) was **not reproduced** with software Vulkan.
- The same exit code was reproduced on SwiftShader through a different path: a device without 16-bit storage makes model load fail, and teardown then crashes. Intel Iris Xe supports 16-bit storage, so this is probably not the tester's case.
- On a working Vulkan device (lavapipe) the exe loads and transcribes without crashing, so the Iris Xe crash is likely specific to the Intel driver or hardware path. That needs the real machine: a `whisper-server-vulkan.log` with the lines before the assert, and a run with `GGML_NO_BACKTRACE=1` to see the underlying exception.
- No code change. Koe already falls back to the CPU build when the Vulkan server exits before answering (`start_failed`) or fails its first request (`first_transcription_failed`), and keeps that choice in backend.json.

## Notes for next time
- On GitHub's Windows runners a software ICD has to be registered in HKLM (env vars are ignored when elevated), and `GGML_VK_VISIBLE_DEVICES=0` is needed because ggml-vulkan skips CPU-type devices.
- lavapipe on 2 cores is far too slow for small-q5_1 with the whole window; use base-q5_1 and a short window to exercise the compute path.
