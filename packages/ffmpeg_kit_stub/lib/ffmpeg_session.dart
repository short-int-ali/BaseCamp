import 'return_code.dart';

class FFmpegSession {
  final ReturnCode? _code;
  FFmpegSession.failed() : _code = const ReturnCode(1);

  Future<ReturnCode?> getReturnCode() async => _code;
  Future<String?> getOutput() async => null;
  int getSessionId() => -1;
}
