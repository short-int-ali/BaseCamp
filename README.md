# Base Camp

A localized, multimodal emergency safety system. 100% offline. All
inference runs on-device via LiteRT-LM with Gemma 4 E2B int4.

Completely compiled apk consisting of the model and all the necessary files is hosted at:
https://www.kaggle.com/datasets/ali025/base-camp-complete-apk

> **Non-Diagnostic Decision Support. Follow local protocols.**

## Status

Initial scaffold. This pass ships:

- `pubspec.yaml` wired for `flutter_litert_lm` + `cactus` + camera.
- `VisionProcessor` — Snap-and-Solve vision inference for
  Pills / Plants / Patients modes.
- `EmergencyUI` — high-contrast camera-first UI with the persistent
  legal disclaimer.

Deferred (see `/lib/modules/lang/`, future wearable module):
Multilingual Medical Gateway, Body Area Network / Wear OS BLE bridge,
real medical KB seed.

## Getting started

1. Install Flutter 3.22+ and the Dart SDK.
2. Drop the LiteRT-LM model bundle at:

   ```
   assets/models/gemma4_e2b_int4.litertlm
   ```

   On Android the bundle can also be `adb push`'d to the app-specific
   external files dir (`/sdcard/Android/data/<package>/files/`) — the
   loader checks app-support first, that location second, and the
   asset bundle last. The app refuses to leave the first-boot gate
   until one of those locations contains the file.

3. `flutter pub get`
4. `flutter run` (Android API 24+ / iOS 13+)

## Layout

```
lib/
  main.dart
  theme/emergency_theme.dart
  ui/emergency_ui.dart
  modules/
    vision/            # Snap-and-Solve
    lang/              # Multilingual gateway (reserved)
  database/            # Local RAG / medical KB
```

## Offline guarantee

`pubspec.yaml` intentionally omits every HTTP client. Any PR that adds
`http`, `dio`, `google_generative_ai`, or similar must be rejected.
