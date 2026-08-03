import 'package:a7_protocol/a7_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/audio_controller.dart';
import '../device/a7_device.dart';
import '../device/a7_state.dart';
import 'audio_status_panel.dart';
import 'files_screen.dart';

class DeviceScreen extends ConsumerWidget {
  const DeviceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(a7Provider);
    final dev = ref.read(a7Provider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: Text(s.device == null ? '设备' : 'X Note · ${s.device!.sn}'),
        actions: [
          IconButton(
            tooltip: '断开连接',
            icon: const Icon(Icons.bluetooth_disabled),
            onPressed: () {
              dev.disconnect();
              Navigator.maybePop(context);
            },
          ),
        ],
      ),
      body: _body(context, s, dev),
    );
  }

  Widget _body(BuildContext context, A7State s, A7Device dev) {
    switch (s.phase) {
      case A7Phase.connecting:
        return _loading('连接中…');
      case A7Phase.binding:
        return _loading('绑定中…（0x03 配对码 183396,5 秒内完成）');
      case A7Phase.error:
        return _error(s.error, () {
          if (s.device != null) dev.connect(s.device!);
        });
      default:
        final info = s.info;
        if (info == null) return _loading('读取设备信息…');
        return _info(context, info, dev);
    }
  }

  Widget _loading(String t) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(t),
          ],
        ),
      );

  Widget _error(String? e, VoidCallback retry) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 32), child: Text(e ?? '出错了', textAlign: TextAlign.center)),
            const SizedBox(height: 12),
            FilledButton(onPressed: retry, child: const Text('重试')),
          ],
        ),
      );

  Widget _info(BuildContext context, DeviceInfo i, A7Device dev) {
    final charge = ['未充电', '充电中', '已充满'][i.charging.clamp(0, 2).toInt()];
    final rec = ['未录音', '录音中', '已暂停'][i.recording.clamp(0, 2).toInt()];
    final seg = ['30 分钟', '1 小时', '2 小时', '3 小时'][i.segment.clamp(0, 3).toInt()];
    final mode = i.mode == 2 ? '电话' : '普通';
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _battery(i),
        _storage(i),
        _tile(Icons.fiber_manual_record, '录音状态', rec),
        _tile(Icons.info_outline, '固件版本', i.version),
        _tile(Icons.memory, '型号', i.model),
        _tile(Icons.phone_in_talk, '模式', mode),
        _tile(Icons.power, '充电', charge),
        _tile(Icons.graphic_eq, '降噪等级', '${i.denoise}'),
        _tile(Icons.timelapse, '分段时长', seg),
        const SizedBox(height: 16),
        const _RealtimeCard(),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FilesScreen()),
          ),
          icon: const Icon(Icons.folder),
          label: const Text('文件列表'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: dev.refreshInfo,
          icon: const Icon(Icons.refresh),
          label: const Text('刷新设备信息'),
        ),
      ],
    );
  }

  Widget _battery(DeviceInfo i) => Card(
        child: ListTile(
          leading: Icon(
            i.battery > 20 ? Icons.battery_full : Icons.battery_alert,
            color: i.battery > 20 ? Colors.green : Colors.orange,
          ),
          title: const Text('电量'),
          trailing: Text('${i.battery}%',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        ),
      );

  Widget _storage(DeviceInfo i) {
    final used = i.totalMb - i.freeMb;
    final pct = i.totalMb == 0 ? 0.0 : used / i.totalMb;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sd_storage),
                const SizedBox(width: 8),
                const Text('存储'),
                const Spacer(),
                Text('${_gb(i.freeMb)} 可用 / ${_gb(i.totalMb)}'),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: pct, minHeight: 8),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(IconData ic, String k, String v) => Card(
        child: ListTile(
          leading: Icon(ic),
          title: Text(k),
          trailing: Text(v, style: const TextStyle(fontSize: 16)),
        ),
      );

  static String _gb(int mb) =>
      mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '$mb MB';
}

/// 真机实时流:0x06 开录 → 边录边播 B0B3(无界 LiveMp3Source)。
class _RealtimeCard extends ConsumerWidget {
  const _RealtimeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audio = ref.read(audioControllerProvider.notifier);
    final transport = ref.read(transportProvider);
    final s = ref.watch(audioControllerProvider);
    final playing = s.phase == AudioPhase.realtimePlaying;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('实时流(边录边播)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('点「录音并播放」会发 0x06 开录,请勿按机身键',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: playing ? null : () => audio.playDeviceRealtime(transport),
                    icon: const Icon(Icons.mic),
                    label: const Text('录音并播放'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => audio.stopDevice(transport),
                    icon: const Icon(Icons.stop),
                    label: const Text('停录停播'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const AudioStatusPanel(),
          ],
        ),
      ),
    );
  }
}
