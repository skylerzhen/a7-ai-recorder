import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../device/a7_device.dart';
import '../device/a7_state.dart';
import 'device_settings_screen.dart';
import 'scan_screen.dart';
import 'theme.dart';

/// 指示器视图类别(纯映射,便于单测覆盖 a7Provider 各 phase + 电量)。
enum ConnKind { connected, lowBattery, connecting, disconnected, error }

class ConnView {
  const ConnView(this.kind, this.text);
  final ConnKind kind;
  final String text;
}

/// A7State → 指示器视图(纯函数,无副作用):
/// ready+有device 看电量(<20 告警);scanning/connecting/binding=连接中;idle/无device=未连接;error=异常。
ConnView connViewOf({required A7Phase phase, required bool hasDevice, int? battery}) {
  switch (phase) {
    case A7Phase.ready:
      if (!hasDevice) return const ConnView(ConnKind.disconnected, '录音卡 未连接 · 点此连接');
      if (battery == null) return const ConnView(ConnKind.connected, '录音卡 已连接');
      if (battery < 20) return ConnView(ConnKind.lowBattery, '录音卡 已连接 · $battery%(电量低)');
      return ConnView(ConnKind.connected, '录音卡 已连接 · $battery%');
    case A7Phase.scanning:
    case A7Phase.connecting:
    case A7Phase.binding:
      return const ConnView(ConnKind.connecting, '连接中…');
    case A7Phase.error:
      return const ConnView(ConnKind.error, '连接异常 · 点此重试');
    case A7Phase.idle:
      return const ConnView(ConnKind.disconnected, '录音卡 未连接 · 点此连接');
  }
}

/// 录音卡连接状态指示器(可复用):watch(a7Provider) 实时驱动。
/// 点击:已连接/连接中 → 设备与设置页;未连接 → 连接流程(ScanScreen);异常 → 就地重连。
class ConnectionIndicator extends ConsumerWidget {
  const ConnectionIndicator({super.key, this.compact = false});

  /// compact:AppBar 右上角小图标(连接时跟一个小号电量%),无整条文字。点击行为不变。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(a7Provider);
    final v = connViewOf(phase: s.phase, hasDevice: s.device != null, battery: s.info?.battery);
    final (fg, bg, icon) = _style(v.kind);
    if (compact) return _compact(context, ref, s, v, fg, icon);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: InkWell(
        onTap: () => _onTap(context, ref, s),
        borderRadius: BorderRadius.circular(AppRadius.field),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m, vertical: 9),
          child: Row(
            children: [
              if (v.kind == ConnKind.connecting)
                SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
              else
                Icon(icon, size: 17, color: fg),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: Text(v.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption.copyWith(color: fg, fontWeight: FontWeight.w600)),
              ),
              Icon(Icons.chevron_right, size: 16, color: fg.withValues(alpha: 0.6)),
            ],
          ),
        ),
      ),
    );
  }

  /// 紧凑渲染:小图标(+ 连接时电量%);完整文案进 tooltip;点击分发同完整版。
  Widget _compact(BuildContext context, WidgetRef ref, A7State s, ConnView v, Color fg, IconData icon) {
    final battery = s.info?.battery;
    final showBattery = battery != null && (v.kind == ConnKind.connected || v.kind == ConnKind.lowBattery);
    return Tooltip(
      message: v.text,
      child: InkResponse(
        onTap: () => _onTap(context, ref, s),
        radius: 22,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (v.kind == ConnKind.connecting)
                SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2, color: fg))
              else
                Icon(icon, size: 20, color: fg),
              if (showBattery) ...[
                const SizedBox(width: 3),
                Text('$battery%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  (Color, Color, IconData) _style(ConnKind k) => switch (k) {
        ConnKind.connected => (AppColors.ok, AppColors.okBg, Icons.mic),
        ConnKind.lowBattery => (AppColors.warn, AppColors.warnBg, Icons.battery_alert),
        ConnKind.connecting => (AppColors.teal, AppColors.tealSoft, Icons.bluetooth_searching),
        ConnKind.disconnected => (AppColors.inkSoft, const Color(0xFFF0F0EA), Icons.bluetooth_disabled),
        ConnKind.error => (AppColors.danger, AppColors.dangerBg, Icons.error_outline),
      };

  void _onTap(BuildContext context, WidgetRef ref, A7State s) {
    final dev = ref.read(a7Provider.notifier);
    switch (s.phase) {
      case A7Phase.idle:
        _push(context, const ScanScreen()); // 未连接 → 连接流程
      case A7Phase.error:
        if (s.device != null) {
          dev.connect(s.device!); // 点此重试:就地重连
        } else {
          _push(context, const ScanScreen());
        }
      case A7Phase.ready:
        if (s.device == null) {
          _push(context, const ScanScreen());
        } else {
          _push(context, const DeviceSettingsScreen());
        }
      case A7Phase.scanning:
      case A7Phase.connecting:
      case A7Phase.binding:
        _push(context, const DeviceSettingsScreen()); // 看连接进度
    }
  }

  void _push(BuildContext context, Widget screen) =>
      Navigator.push(context, MaterialPageRoute(builder: (_) => screen));
}
