import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 全局录音状态：首页/其他页面也能看到「正在录音」。
class LiveRecordingState {
  const LiveRecordingState({
    this.active = false,
    this.ready = false,
    this.elapsedSec = 0,
    this.sourceLabel = '',
  });

  final bool active;
  final bool ready;
  final int elapsedSec;
  final String sourceLabel;

  LiveRecordingState copyWith({
    bool? active,
    bool? ready,
    int? elapsedSec,
    String? sourceLabel,
  }) =>
      LiveRecordingState(
        active: active ?? this.active,
        ready: ready ?? this.ready,
        elapsedSec: elapsedSec ?? this.elapsedSec,
        sourceLabel: sourceLabel ?? this.sourceLabel,
      );
}

final liveRecordingProvider =
    NotifierProvider<LiveRecordingNotifier, LiveRecordingState>(LiveRecordingNotifier.new);

class LiveRecordingNotifier extends Notifier<LiveRecordingState> {
  @override
  LiveRecordingState build() => const LiveRecordingState();

  void onStart({required String sourceLabel}) {
    state = LiveRecordingState(active: true, sourceLabel: sourceLabel);
  }

  void onReady() => state = state.copyWith(ready: true);

  void onTick(int sec) {
    if (!state.active) return;
    state = state.copyWith(elapsedSec: sec);
  }

  void onStop() => state = const LiveRecordingState();
}
