import 'package:a7_protocol/a7_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ai/backend.dart';
import '../audio/audio_controller.dart';
import '../device/a7_device.dart';
import '../device/a7_state.dart';
import '../library/recording_store.dart';
import 'scan_screen.dart';
import 'theme.dart';
import 'wifi_transfer_screen.dart';

/// 设备与设置:录音卡状态/电量/存储/信息 + 连接/断开/重连/刷新;后端地址;清空全部录音。
/// 复用 a7Provider(实时驱动)与 DeviceInfo 字段(同 device_screen);视觉走 theme.dart token。
class DeviceSettingsScreen extends ConsumerWidget {
  const DeviceSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(a7Provider);
    return Scaffold(
      appBar: AppBar(title: const Text('设备与设置')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.m),
        children: [
          Text('录音卡', style: AppText.section),
          const SizedBox(height: AppSpacing.s),
          _deviceArea(context, ref, s),
          const SizedBox(height: AppSpacing.xl),
          Text('通用', style: AppText.section),
          const SizedBox(height: AppSpacing.s),
          _backendCard(context, ref),
          const SizedBox(height: AppSpacing.s),
          _clearAllCard(context, ref),
        ],
      ),
    );
  }

  // ───────────────────────── 录音卡区(随 a7Provider 实时变) ─────────────────────────

  Widget _deviceArea(BuildContext context, WidgetRef ref, A7State s) {
    final dev = ref.read(a7Provider.notifier);
    switch (s.phase) {
      case A7Phase.scanning:
      case A7Phase.connecting:
      case A7Phase.binding:
        return _shell(
          child: Row(children: [
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: AppSpacing.m),
            Text(s.phase == A7Phase.binding ? '绑定中…' : '连接中…', style: AppText.body),
          ]),
        );
      case A7Phase.error:
        return _errorCard(context, dev, s);
      case A7Phase.ready:
        return _connectedArea(context, dev, s);
      case A7Phase.idle:
        return _disconnectedCard(context);
    }
  }

  Widget _disconnectedCard(BuildContext context) => _shell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.bluetooth_disabled, color: AppColors.inkSoft, size: 20),
              const SizedBox(width: AppSpacing.s),
              Text('录音卡 未连接', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: AppSpacing.xs),
            Text('连上 A7 录音豆,远场收音更好。', style: AppText.faint),
            const SizedBox(height: AppSpacing.m),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _push(context, const ScanScreen()),
                icon: const Icon(Icons.bluetooth_searching),
                label: const Text('连接录音卡'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.teal, foregroundColor: Colors.white),
              ),
            ),
          ],
        ),
      );

  Widget _errorCard(BuildContext context, A7Device dev, A7State s) => _shell(
        border: AppColors.danger.withValues(alpha: 0.3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.error_outline, color: AppColors.danger, size: 20),
              const SizedBox(width: AppSpacing.s),
              Text('连接异常', style: AppText.body.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600)),
            ]),
            if (s.error != null) ...[
              const SizedBox(height: 4),
              Text(s.error!, style: AppText.caption, maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: AppSpacing.m),
            Row(children: [
              if (s.device != null) ...[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => dev.connect(s.device!),
                    icon: const Icon(Icons.refresh),
                    label: const Text('重连'),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.teal, foregroundColor: Colors.white),
                  ),
                ),
                const SizedBox(width: AppSpacing.s),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _push(context, const ScanScreen()),
                  icon: const Icon(Icons.bluetooth_searching),
                  label: const Text('重新扫描'),
                ),
              ),
            ]),
          ],
        ),
      );

  Widget _connectedArea(BuildContext context, A7Device dev, A7State s) {
    final info = s.info;
    return Column(
      children: [
        _shell(
          border: AppColors.ok.withValues(alpha: 0.3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                const Icon(Icons.mic, color: AppColors.ok, size: 20),
                const SizedBox(width: AppSpacing.s),
                Text('已连接', style: AppText.body.copyWith(color: AppColors.ok, fontWeight: FontWeight.w700)),
                const SizedBox(width: AppSpacing.s),
                Expanded(
                  child: Text(s.device == null ? '' : 'X Note · ${s.device!.sn}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: AppText.caption),
                ),
                if (info != null) _batteryPill(info.battery),
              ]),
              if (info == null) ...[
                const SizedBox(height: AppSpacing.m),
                Row(children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: AppSpacing.s),
                  Text('读取设备信息…', style: AppText.caption),
                ]),
              ] else ...[
                const SizedBox(height: AppSpacing.m),
                _storage(info),
                const SizedBox(height: AppSpacing.s),
                _kv(Icons.fiber_manual_record, '录音状态', _recLabel(info.recording)),
                _kv(Icons.power, '充电', _chargeLabel(info.charging)),
                _kv(Icons.info_outline, '固件版本', info.version),
                _kv(Icons.memory, '型号', info.model),
                _kv(Icons.phone_in_talk, '模式', info.mode == 2 ? '电话' : '普通'),
                _kv(Icons.graphic_eq, '降噪等级', '${info.denoise}'),
                _kv(Icons.timelapse, '分段时长', _segLabel(info.segment)),
              ],
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: dev.refreshInfo,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新'),
            ),
          ),
          const SizedBox(width: AppSpacing.s),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: dev.disconnect,
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('断开'),
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger),
            ),
          ),
        ]),
        const SizedBox(height: AppSpacing.s),
        // 实时监听(边录边听):新机走原生低延迟 Opus 解码,旧机走 LiveMp3Source(均显示)
        _MonitorTile(opus: audioCodecOf(model: info?.model, sn: s.device?.sn) == 'opus'),
        // Wi-Fi 快传:仅新机(model X95-AINOTE / SN 前缀 Q95)显示;旧机隐藏,维持 BLE 取文件
        if (info != null && isWifiCapable(model: info.model, sn: s.device?.sn)) ...[
          const SizedBox(height: AppSpacing.s),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: () => Navigator.push(
                  context, MaterialPageRoute(builder: (_) => const WifiTransferScreen())),
              icon: const Icon(Icons.wifi),
              label: const Text('Wi-Fi 快传(从卡上拉录音,快)'),
              style: FilledButton.styleFrom(backgroundColor: AppColors.teal, foregroundColor: Colors.white),
            ),
          ),
        ],
      ],
    );
  }

  Widget _batteryPill(int battery) {
    final low = battery < 20;
    final c = low ? AppColors.warn : AppColors.ok;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(low ? Icons.battery_alert : Icons.battery_full, size: 13, color: c),
          const SizedBox(width: 3),
          Text('$battery%', style: AppText.caption.copyWith(color: c, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _storage(DeviceInfo i) {
    final used = i.totalMb - i.freeMb;
    final pct = i.totalMb == 0 ? 0.0 : used / i.totalMb;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Icon(Icons.sd_storage, size: 16, color: AppColors.inkSoft),
          const SizedBox(width: 6),
          Text('存储', style: AppText.caption),
          const Spacer(),
          Text('${_gb(i.freeMb)} 可用 / ${_gb(i.totalMb)}', style: AppText.caption),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
              value: pct, minHeight: 7, backgroundColor: AppColors.line, color: AppColors.teal),
        ),
      ],
    );
  }

  Widget _kv(IconData ic, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Icon(ic, size: 16, color: AppColors.inkSoft),
          const SizedBox(width: 8),
          Text(k, style: AppText.caption),
          const Spacer(),
          Text(v, style: AppText.body.copyWith(fontSize: 14)),
        ]),
      );

  // ───────────────────────── 通用区 ─────────────────────────

  Widget _backendCard(BuildContext context, WidgetRef ref) => _tappableCard(
        icon: Icons.dns_outlined,
        title: '后端地址',
        subtitle: ref.watch(backendBaseProvider),
        onTap: () => _editBackend(context, ref),
      );

  Widget _clearAllCard(BuildContext context, WidgetRef ref) => _tappableCard(
        icon: Icons.delete_sweep_outlined,
        iconColor: AppColors.danger,
        title: '清空全部录音',
        subtitle: '删除所有会议与音频,不可恢复',
        onTap: () => _confirmClearAll(context, ref),
      );

  Future<void> _editBackend(BuildContext context, WidgetRef ref) async {
    final v = await showDialog<String>(
      context: context,
      builder: (_) => _BackendDialog(ref.read(backendBaseProvider)),
    );
    if (v != null && v.isNotEmpty) ref.read(backendBaseProvider.notifier).state = v;
  }

  Future<void> _confirmClearAll(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('清空全部录音?'),
        content: const Text('所有会议与音频都会删掉,不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(recordingStoreProvider.notifier).clearAll();
  }

  // ───────────────────────── 复用样式 / 标签 ─────────────────────────

  Widget _shell({required Widget child, Color? border}) => Container(
        padding: const EdgeInsets.all(AppSpacing.m),
        decoration: AppTheme.cardDecoration(border: border),
        child: child,
      );

  Widget _tappableCard({
    required IconData icon,
    Color? iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) =>
      Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: Container(
            padding: const EdgeInsets.all(AppSpacing.m),
            decoration: AppTheme.cardDecoration(),
            child: Row(children: [
              Icon(icon, size: 20, color: iconColor ?? AppColors.teal),
              const SizedBox(width: AppSpacing.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: AppText.body.copyWith(fontWeight: FontWeight.w600, color: iconColor)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              const Icon(Icons.chevron_right, size: 18, color: AppColors.inkFaint),
            ]),
          ),
        ),
      );

  void _push(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));

  static String _recLabel(int r) => ['未录音', '录音中', '已暂停'][r.clamp(0, 2).toInt()];
  static String _chargeLabel(int c) => ['未充电', '充电中', '已充满'][c.clamp(0, 2).toInt()];
  static String _segLabel(int s) => ['30 分钟', '1 小时', '2 小时', '3 小时'][s.clamp(0, 3).toInt()];
  static String _gb(int mb) => mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';
}

/// 实时监听(边录边听)按钮 + 状态:opus=新机原生低延迟 PCM;否则旧机 LiveMp3Source。
class _MonitorTile extends ConsumerWidget {
  const _MonitorTile({required this.opus});
  final bool opus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(audioControllerProvider);
    final playing = s.phase == AudioPhase.realtimePlaying;
    final transport = ref.read(transportProvider);
    final ctrl = ref.read(audioControllerProvider.notifier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 48,
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () =>
                playing ? ctrl.stopMonitor(transport) : ctrl.startMonitor(transport, opus: opus),
            icon: Icon(playing ? Icons.stop : Icons.headphones),
            label: Text(playing ? '停止监听' : '实时监听(边录边听)'),
            style: FilledButton.styleFrom(
              backgroundColor: playing ? AppColors.danger : AppColors.teal,
              foregroundColor: Colors.white,
            ),
          ),
        ),
        if (s.phase == AudioPhase.error && s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.error!,
                style: AppText.caption.copyWith(color: AppColors.danger),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          )
        else if (playing && s.note != null && s.note!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.note!, style: AppText.caption),
          ),
      ],
    );
  }
}

/// 后端地址编辑弹框:自持控制器、在自身 dispose() 释放(同 PrepForm,规避对话框 dispose 崩溃)。
class _BackendDialog extends StatefulWidget {
  const _BackendDialog(this.initial);
  final String initial;

  @override
  State<_BackendDialog> createState() => _BackendDialogState();
}

class _BackendDialogState extends State<_BackendDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('后端地址'),
      content: TextField(
        controller: _ctl,
        decoration: const InputDecoration(
          helperText: '模拟器 10.0.2.2:8787;真机填局域网 IP 或线上域名',
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, _ctl.text.trim()), child: const Text('保存')),
      ],
    );
  }
}
