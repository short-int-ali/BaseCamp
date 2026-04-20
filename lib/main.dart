import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'database/medical_kb.dart';
import 'modules/vision/vision_processor.dart';
import 'theme/emergency_theme.dart';
import 'ui/emergency_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock the UI to portrait. The Emergency Red UI is tuned for
  // one-handed portrait use; the camera preview compositor in
  // emergency_ui.dart assumes portrait.
  await SystemChrome.setPreferredOrientations(const [
    DeviceOrientation.portraitUp,
  ]);

  // Request camera permission up front so first-boot failures surface
  // deterministically rather than inside the camera init future.
  await Permission.camera.request();

  // Single processor for the lifetime of the app. A no-op KB keeps
  // the app functional before the real medical RAG DB is seeded —
  // results will be honest about not being KB-verified.
  final processor = VisionProcessor(kb: const NoopMedicalKb());

  runApp(BaseCampApp(processor: processor));
}

class BaseCampApp extends StatelessWidget {
  const BaseCampApp({super.key, required this.processor});

  final VisionProcessor processor;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Base Camp',
      debugShowCheckedModeBanner: false,
      theme: EmergencyTheme.build(),
      home: EmergencyUI(processor: processor),
    );
  }
}
