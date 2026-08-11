import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'recording_task_handler.dart';

/// 会议录音保活:后台/锁屏时尽量不断麦、不断 BLE 流。
/// Android 用 microphone 前台服务; iOS 靠 UIBackgroundModes + AVAudioSession。
class RecordingKeepAlive {
  RecordingKeepAlive._();

  static bool _inited = false;
  static int _refCount = 0;

  static void init() {
    if (_inited) return;
    _inited = true;
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'a7_recording',
        channelName: '会议录音',
        channelDescription: '后台录音进行中',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// 配置音频会话(录音+播放),后台收音必需。
  static Future<void> configureAudioSession() async {
    final session = await AudioSession.instance;
    await session.configure(
      AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions:
            AVAudioSessionCategoryOptions.defaultToSpeaker |
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.mixWithOthers,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: false,
      ),
    );
    await session.setActive(true);
  }

  static Future<void> start() async {
    _refCount++;
    if (_refCount > 1) return;

    await configureAudioSession();
    await WakelockPlus.enable();

    if (Platform.isAndroid) {
      await _ensureAndroidNotificationPermission();
      if (await FlutterForegroundTask.isRunningService) return;
      final result = await FlutterForegroundTask.startService(
        serviceId: 8787,
        notificationTitle: 'A7 会议录音',
        notificationText: '后台录音进行中，点击返回 App',
        serviceTypes: const [ForegroundServiceTypes.microphone],
        callback: recordingKeepAliveCallback,
      );
      if (result is ServiceRequestFailure) {
        debugPrint('RecordingKeepAlive FGS failed: ${result.error}');
      }
    }
  }

  static Future<void> stop() async {
    if (_refCount <= 0) return;
    _refCount--;
    if (_refCount > 0) return;

    await WakelockPlus.disable();
    if (Platform.isAndroid && await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    try {
      final session = await AudioSession.instance;
      await session.setActive(false);
    } catch (_) {}
  }

  static Future<void> _ensureAndroidNotificationPermission() async {
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }
}
