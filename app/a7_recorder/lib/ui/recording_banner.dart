import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../recording/live_recording_state.dart';
import 'caption_screen.dart';
import 'theme.dart';

/// 醒目的「正在录音」条：列表页也能看到进度，点一下回到会议屏。
class RecordingBanner extends ConsumerWidget {
  const RecordingBanner({super.key, this.compact = false});
  final bool compact;

  static String fmtClock(int sec) =>
      '${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final live = ref.watch(liveRecordingProvider);
    if (!live.active) return const SizedBox.shrink();

    final label = live.ready ? '录音中 ${fmtClock(live.elapsedSec)}' : '正在连接麦克风…';
    final sub = live.sourceLabel.isEmpty ? null : live.sourceLabel;

    return Material(
      color: AppColors.dangerBg,
      child: InkWell(
        onTap: compact
            ? () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CaptionScreen()),
                )
            : null,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.m,
            vertical: compact ? 8 : 10,
          ),
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(color: AppColors.danger, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(label,
                        style: AppText.body.copyWith(
                          fontWeight: FontWeight.w700,
                          color: AppColors.danger,
                        )),
                    if (sub != null)
                      Text(sub, style: AppText.caption.copyWith(color: AppColors.danger)),
                  ],
                ),
              ),
              if (compact)
                Text('返回会议', style: AppText.caption.copyWith(color: AppColors.danger)),
            ],
          ),
        ),
      ),
    );
  }
}
