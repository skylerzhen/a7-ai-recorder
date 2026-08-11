import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Android 前台服务占位 TaskHandler;实际录音仍在主 Isolate(CaptionScreen)。
@pragma('vm:entry-point')
void recordingKeepAliveCallback() {
  FlutterForegroundTask.setTaskHandler(_RecordingKeepAliveHandler());
}

class _RecordingKeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}
