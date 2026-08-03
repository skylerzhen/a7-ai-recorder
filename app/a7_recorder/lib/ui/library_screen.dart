import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../library/recording.dart';
import '../library/recording_store.dart';
import 'caption_screen.dart';
import 'connection_indicator.dart';
import 'detail_screen.dart';
import 'device_settings_screen.dart';
import 'theme.dart';

/// 主页·我的会议(战情台):信息丰富的会议卡列表 + 醒目「开始会议」。
///
/// v2 收拢:开发屏入口(从 A7 拉取 / 内置样本 / 导入 / 后端齿轮)已从首页收起 ——
/// 对应功能代码(ScanScreen / store.addBuiltinSample / store.addUpload)仍在,只是不在首页;
/// 后端地址暂收进右上「更多」菜单,设置棒再正式安置。
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recs = ref.watch(recordingStoreProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('我的会议'),
        actions: [
          const ConnectionIndicator(compact: true),
          IconButton(
            tooltip: '设备与设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const DeviceSettingsScreen())),
          ),
        ],
      ),
      body: recs.isEmpty
          ? _empty()
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.s, AppSpacing.m, AppSpacing.s),
              itemCount: recs.length,
              itemBuilder: (_, i) => _MeetingCard(rec: recs[i]),
            ),
      bottomNavigationBar: _startBar(context),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.forum_outlined, size: 48, color: AppColors.inkFaint),
              const SizedBox(height: AppSpacing.m),
              Text('还没有会议', style: AppText.title),
              const SizedBox(height: AppSpacing.xs),
              Text('点下面「开始会议」开第一场', style: AppText.faint),
            ],
          ),
        ),
      );

  Widget _startBar(BuildContext context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.s, AppSpacing.m, AppSpacing.m),
          child: SizedBox(
            height: 54,
            child: FilledButton.icon(
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const CaptionScreen())),
              icon: const Icon(Icons.mic_rounded, size: 22),
              label: const Text('开始会议', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.teal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
              ),
            ),
          ),
        ),
      );

}

/// 一张会议卡:客户/标题 · 时间/时长/状态 · 目标摘要 · 问AI/提示统计;点进详情、左滑删除。
class _MeetingCard extends ConsumerWidget {
  const _MeetingCard({required this.rec});
  final Recording rec;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Dismissible(
      key: ValueKey(rec.id),
      direction: DismissDirection.endToStart,
      background: _swipeBg(),
      confirmDismiss: (_) => _confirmDelete(context),
      onDismissed: (_) => ref.read(recordingStoreProvider.notifier).remove(rec.id),
      child: _card(context),
    );
  }

  Widget _card(BuildContext context) {
    final st = _statusOf(rec);
    final ask = rec.askHistory.length;
    final cue = rec.cueHistory.length;
    final hasGoal = rec.goal != null && rec.goal!.trim().isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      clipBehavior: Clip.antiAlias,
      decoration: AppTheme.cardDecoration(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => DetailScreen(id: rec.id))),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶行:来源图标 + 主标题(clientName 字段后续棒再加,先用 title)+ 状态标签
                Row(
                  children: [
                    Icon(_sourceIcon(rec.source), size: 16, color: AppColors.teal),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        rec.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s),
                    _statusChip(st),
                  ],
                ),
                const SizedBox(height: 6),
                // 次行:时间 · 时长(左)+ 问AI/提示统计(右,>0 才显示)
                Row(
                  children: [
                    Text('${_date(rec.createdAt)}  ·  ${_dur(rec.durationMs)}', style: AppText.caption),
                    const Spacer(),
                    if (ask > 0) _stat(Icons.auto_awesome, AppColors.cueAccent, ask),
                    if (ask > 0 && cue > 0) const SizedBox(width: AppSpacing.s),
                    if (cue > 0) _stat(Icons.notifications_active, AppColors.adviseAccent, cue),
                  ],
                ),
                // 第三行:🎯 目标摘要(有才显示,一行省略)
                if (hasGoal) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.track_changes, size: 14, color: AppColors.inkFaint),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(rec.goal!.trim(),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _swipeBg() => Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        padding: const EdgeInsets.only(right: AppSpacing.l),
        decoration: BoxDecoration(
          color: AppColors.dangerBg,
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.delete_outline, size: 20, color: AppColors.danger),
            const SizedBox(width: 6),
            Text('删除', style: AppText.caption.copyWith(color: AppColors.danger, fontWeight: FontWeight.w700)),
          ],
        ),
      );

  Future<bool> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除这场会议?'),
        content: const Text('音频和记录都会删掉,不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Widget _stat(IconData icon, Color color, int n) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 2),
          Text('$n', style: AppText.caption.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      );

  /// 状态标签:有 summary→已纪要;done 无 summary→待纪要;处理中/待处理/出错。
  (String, Color, IconData) _statusOf(Recording r) {
    // 已纪要 = 老的结构化 summary 或 新的流式 summaryText 任一存在(修「生成后仍显示待纪要」)
    final hasSummary = r.summary != null || (r.summaryText?.trim().isNotEmpty ?? false);
    if (hasSummary) return ('已纪要', AppColors.teal, Icons.check_circle);
    return switch (r.status) {
      RecStatus.done => ('待纪要', AppColors.cueAccent, Icons.schedule),
      RecStatus.processing => ('处理中', AppColors.adviseAccent, Icons.autorenew),
      RecStatus.unprocessed => ('待处理', AppColors.inkFaint, Icons.fiber_manual_record),
      RecStatus.error => ('出错', AppColors.danger, Icons.error_outline),
    };
  }

  Widget _statusChip((String, Color, IconData) st) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: st.$2.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.chip),
          border: Border.all(color: st.$2.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(st.$3, size: 12, color: st.$2),
            const SizedBox(width: 3),
            Text(st.$1, style: AppText.caption.copyWith(color: st.$2, fontWeight: FontWeight.w600)),
          ],
        ),
      );

  static IconData _sourceIcon(RecSource s) => switch (s) {
        RecSource.device => Icons.bluetooth,
        RecSource.sample => Icons.memory,
        RecSource.live => Icons.mic,
        RecSource.upload => Icons.upload_file,
      };

  static String _date(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} '
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  static String _dur(int ms) {
    final s = (ms / 1000).round();
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }
}
