import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_controller.dart';
import 'audio_status_panel.dart';

/// 模拟器音频管线演示页(Fake 回放真采样字节)。
/// 两个按钮:播放实时流(无界 B0B3)、下载并播放文件(B0B4→重组→裁头→播)。
class PlayScreen extends ConsumerWidget {
  const PlayScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(audioControllerProvider);
    final c = ref.read(audioControllerProvider.notifier);
    final busy = s.phase == AudioPhase.downloading;

    return Scaffold(
      appBar: AppBar(title: const Text('音频管线 Demo')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('真机采样字节经 Fake 回放 · 不碰硬件',
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => c.playRealtime(),
              icon: const Icon(Icons.podcasts),
              label: const Text('播放实时流(无界 B0B3)'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: busy ? null : () => c.downloadAndPlayFile(),
              icon: const Icon(Icons.download),
              label: const Text('下载并播放文件(B0B4)'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => c.stop(),
              icon: const Icon(Icons.stop),
              label: const Text('停止'),
            ),
            const SizedBox(height: 24),
            const AudioStatusPanel(),
          ],
        ),
      ),
    );
  }
}
