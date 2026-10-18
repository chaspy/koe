### Windows
- `windows/build.sh` checks the SHA-256 of the whisper.cpp release zip and of the Vulkan build of whisper-server on every build (pinned next to `WHISPER_TAG`, like sherpa-onnx), unpacks whisper-server again from the checked zip each time, and stops instead of packaging a file that does not match.
