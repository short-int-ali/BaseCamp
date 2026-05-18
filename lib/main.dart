import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'database/file_medical_kb.dart';
import 'database/medical_kb.dart';
import 'services/model_engine.dart';
import 'ui/emergency_ui.dart';

Future<void> main() async {
  // #region agent log
  print('[DBG-b37fdb] H1 main() ENTERED — Dart engine alive');
  // #endregion
  WidgetsFlutterBinding.ensureInitialized();

  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);

  // #region agent log
  print('[DBG-b37fdb] H1 orientations set — pre-engine');
  // #endregion

  final engine = ModelEngine();
  MedicalKb kb;
  try {
    kb = await FileMedicalKb.load();
    // #region agent log
    print('[DBG-b37fdb] H5 FileMedicalKb loaded OK');
    // #endregion
  } catch (e, st) {
    debugPrint('FileMedicalKb.load failed — using empty KB. $e\n$st');
    // #region agent log
    print('[DBG-b37fdb] H5 FileMedicalKb FAILED: $e');
    // #endregion
    kb = const NoopMedicalKb();
  }

  // #region agent log
  print('[DBG-b37fdb] H1 runApp about to execute');
  // #endregion
  runApp(EmergencyUI(engine: engine, kb: kb));
}
