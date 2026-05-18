# Silero VAD assets

Hands-free mode uses **Silero VAD** only (no wake-word). When you stop
speaking for **2 seconds**, the buffered clip is sent to Whisper STT, then
Gemma.

## Required file

```
assets/sherpa/vad/silero_vad.onnx
```

Download:

<https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx>

## adb-push

```sh
adb shell mkdir -p /sdcard/Android/data/com.example.base_camp/files/sherpa/vad

adb push silero_vad.onnx \
  /sdcard/Android/data/com.example.base_camp/files/sherpa/vad/
```
