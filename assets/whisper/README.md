# Whisper GGML (offline STT)

Base Camp transcribes user speech with **Whisper Tiny** (`ggml-tiny.bin`) on
**CPU only** before sending text to Gemma — no network, no wake-word engine.

## Required file

```
assets/whisper/ggml-tiny.bin
```

Multilingual tiny (~75 MB) or quantized `ggml-tiny-q5_0.bin` renamed to
`ggml-tiny.bin` if you need a smaller APK.

Download from the official bundle:

<https://huggingface.co/ggerganov/whisper.cpp/tree/main>

Direct link (tiny):

<https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin>

## Resolution order

1. `<application support>/ggml-tiny.bin` (staged from assets on first run)
2. Android external files: `<external>/whisper/ggml-tiny.bin` (adb push)
3. Flutter asset bundle: `assets/whisper/ggml-tiny.bin`

## adb-push (Android)

```sh
adb shell mkdir -p /sdcard/Android/data/com.example.base_camp/files/whisper

adb push ggml-tiny.bin \
  /sdcard/Android/data/com.example.base_camp/files/whisper/
```

## Language detection

Whisper runs with `language: auto`. Detected language (`ur`, `en`, or
`unknown` → English fallback) is inferred from the transcript script and
logged as `USER_LANGUAGE_DETECTED` in the session log.
