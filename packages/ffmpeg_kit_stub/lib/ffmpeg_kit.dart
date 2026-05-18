import 'ffmpeg_session.dart';

class FFmpegKit {
  static Future<FFmpegSession> execute(String command) async {
    return FFmpegSession.failed();
  }

  static Future<FFmpegSession> executeWithArguments(
      List<String> arguments) async {
    return FFmpegSession.failed();
  }
}
