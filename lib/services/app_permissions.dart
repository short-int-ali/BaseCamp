import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:permission_handler/permission_handler.dart';

/// Request camera + microphone after the Flutter engine and plugins are
/// registered. Call from the first frame of the root widget — not from
/// [main], which runs before plugin registration and triggers
/// [MissingPluginException] on some Android builds.
Future<void> requestAppPermissions() async {
  try {
    final perms = <Permission>[
      Permission.camera,
      Permission.microphone,
    ];
    await perms.request();
  } on MissingPluginException catch (e) {
    debugPrint(
      'AppPermissions: permission_handler not linked ($e). '
      'Run `flutter clean && flutter pub get && flutter run`. '
      'Camera/mic will prompt when used.',
    );
  } catch (e, st) {
    debugPrint('AppPermissions: request failed: $e\n$st');
  }
}

/// Session PDFs/TXT logs use app-scoped directories only (`getExternalStorageDirectory` /
/// application documents). No legacy storage permission is required on Android 10+.
Future<bool> requestStorageForSessionLogs() async {
  return true;
}
