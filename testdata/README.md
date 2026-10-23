# Audio quality golden cases

`audio-quality.json` freezes outputs of the original Swift `AudioQuality` from
koe-dev commit a66a1ea, before making the C API the only implementation.
The expected values were captured by running that Swift code, not the C++ code.
Do not regenerate expected values from the implementation under test.

Each case describes synthetic mono int16 PCM at 16 kHz. Build 480-sample windows:
`background_windows` at `background`, then `voice_windows` at `amplitude`, then
`background_windows` at `background`. Within each window alternate +amplitude and
-amplitude, starting positive. Append `tail_samples` zeros. No real recordings
or transcripts are used. `quality` is empty when there is no voiced window;
`too_quiet` is the original Swift warning decision.

The cases cover empty/silent/muted input, low and normal levels, both sides of
quietness and speech gates, the minimum speech duration, partial/short recordings,
and the clipping threshold. Both language bindings must use these same fixtures.
