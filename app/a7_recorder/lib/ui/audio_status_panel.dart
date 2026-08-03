import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../audio/audio_controller.dart';

/// 音频状态面板:阶段/缓冲提示 + 下载进度 + 播放器位置。Demo 页与真机页共用。
class AudioStatusPanel extends ConsumerWidget {
  const AudioStatusPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(audioControllerProvider);
    final player = ref.read(audioControllerProvider.notifier).player;
    if (s.phase == AudioPhase.idle && s.note == null && s.error == null) {
      return const SizedBox.shrink();
    }
    final label = switch (s.phase) {
      AudioPhase.idle => '空闲',
      AudioPhase.realtimePlaying => '实时流播放中',
      AudioPhase.downloading => '下载重组中',
      AudioPhase.filePlaying => '文件播放中',
      AudioPhase.error => '错误',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.graphic_eq, size: 18, color: Colors.teal),
            const SizedBox(width: 8),
            Expanded(child: Text('$label${s.note != null ? ' · ${s.note}' : ''}')),
          ],
        ),
        if (s.total > 0 && s.phase == AudioPhase.downloading) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(value: s.progress),
          const SizedBox(height: 6),
          Text('${s.received} / ${s.total} B  (${(s.progress * 100).toStringAsFixed(1)}%)'),
        ],
        if (s.error != null) ...[
          const SizedBox(height: 8),
          Text('出错:${s.error}', style: const TextStyle(color: Colors.red)),
        ],
        const SizedBox(height: 12),
        _PlayerBar(player: player),
      ],
    );
  }
}

/// 播放进度条:position 推进即「确有在播」的证据(模拟器/真机音频可能不外放但状态可见)。
class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.player});
  final AudioPlayer player;

  String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlayerState>(
      stream: player.playerStateStream,
      builder: (context, snap) {
        final ps = snap.data;
        final playing = ps?.playing ?? false;
        final proc = ps?.processingState ?? ProcessingState.idle;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(playing ? Icons.play_arrow : Icons.pause, color: Colors.teal),
                    const SizedBox(width: 8),
                    Expanded(child: Text('播放器:${playing ? "playing" : "paused"} · $proc')),
                  ],
                ),
                const SizedBox(height: 8),
                StreamBuilder<Duration>(
                  stream: player.positionStream,
                  builder: (context, posSnap) {
                    final pos = posSnap.data ?? Duration.zero;
                    final dur = player.duration ?? Duration.zero;
                    final v = dur.inMilliseconds == 0
                        ? 0.0
                        : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
                    return Column(
                      children: [
                        LinearProgressIndicator(value: v),
                        const SizedBox(height: 6),
                        Text('${_fmt(pos)} / ${_fmt(dur)}'),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
