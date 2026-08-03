import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/recording.dart';
import '../library/recording_store.dart';
import 'ai_client.dart';
import 'backend.dart';

/// 单条会议的纪要生成态(流式累积)。
class SummaryGenState {
  final String text; // 已累积的流式 markdown
  final bool running;
  final String? error;
  const SummaryGenState({this.text = '', this.running = false, this.error});

  SummaryGenState copyWith({String? text, bool? running, String? error, bool clearError = false}) =>
      SummaryGenState(
        text: text ?? this.text,
        running: running ?? this.running,
        error: clearError ? null : (error ?? this.error),
      );
}

/// App 级纪要生成器:owns 流式 /summarize 订阅,按 recordingId 累积文本。
///
/// **关键(异步不中断 / survive navigation)**:这是个**非 autoDispose** 的全局 provider,
/// 订阅握在本 notifier 里(不挂详情 State)。离开详情页时详情 widget 被销毁,但本 provider
/// 不随之 dispose,流式照常跑到 [DONE] 并 `store.update(summaryText=…)` 写回 —— 不用盯着页面。
final summaryGenProvider =
    NotifierProvider<SummaryGen, Map<String, SummaryGenState>>(SummaryGen.new);

class SummaryGen extends Notifier<Map<String, SummaryGenState>> {
  final Map<String, StreamSubscription<String>> _subs = {};

  @override
  Map<String, SummaryGenState> build() {
    ref.onDispose(() {
      for (final s in _subs.values) {
        s.cancel();
      }
      _subs.clear();
    });
    return const {};
  }

  SummaryGenState stateFor(String id) => state[id] ?? const SummaryGenState();

  /// 点按钮触发:流式生成该会议纪要;[DONE] 时写回 recording.summaryText。已在生成则忽略。
  void generate(Recording r) {
    if (stateFor(r.id).running) return;
    _subs[r.id]?.cancel();
    _set(r.id, const SummaryGenState(running: true, text: ''));

    final transcript = (r.transcript ?? const []).map((s) => '${s.speaker}: ${s.text}').join('\n');
    final buf = StringBuffer();

    _subs[r.id] = AiClient.summarizeStream(
      baseUrl: ref.read(backendBaseProvider),
      transcript: transcript,
      goal: r.goal,
      clientBackground: r.clientBackground,
    ).listen(
      (tok) {
        buf.write(tok);
        _set(r.id, stateFor(r.id).copyWith(text: buf.toString()));
      },
      onError: (Object e) {
        _subs.remove(r.id);
        _set(r.id, stateFor(r.id).copyWith(running: false, error: '$e'));
      },
      onDone: () async {
        _subs.remove(r.id);
        final text = buf.toString().trim();
        if (text.isNotEmpty) {
          // 写回录音库(离开详情也会执行到这里 —— 异步不中断)
          await ref.read(recordingStoreProvider.notifier).update(r.copyWith(summaryText: text));
        }
        _set(r.id, stateFor(r.id).copyWith(running: false, text: text));
      },
      cancelOnError: true,
    );
  }

  void _set(String id, SummaryGenState s) {
    state = {...state, id: s};
  }
}
