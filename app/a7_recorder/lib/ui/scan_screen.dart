import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../device/a7_device.dart';
import '../device/a7_state.dart';
import 'ai_test_screen.dart';
import 'caption_screen.dart';
import 'device_screen.dart';
import 'play_screen.dart';

class ScanScreen extends ConsumerWidget {
  const ScanScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(a7Provider);
    final dev = ref.read(a7Provider.notifier);
    final scanning = s.phase == A7Phase.scanning;

    return Scaffold(
      appBar: AppBar(
        title: const Text('A7 录音笔'),
        actions: [
          IconButton(
            tooltip: '近实时字幕',
            icon: const Icon(Icons.closed_caption),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CaptionScreen()),
            ),
          ),
          IconButton(
            tooltip: 'AI 测试(转写+纪要)',
            icon: const Icon(Icons.auto_awesome),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AiTestScreen()),
            ),
          ),
          IconButton(
            tooltip: '音频管线 Demo',
            icon: const Icon(Icons.graphic_eq),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PlayScreen()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (scanning) const LinearProgressIndicator(),
          Expanded(
            child: s.found.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        scanning
                            ? '扫描中…\n（设备无连接会休眠,请按一下机身按键唤醒）'
                            : '点右下角「扫描」开始查找 A7',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black54),
                      ),
                    ),
                  )
                : ListView(
                    children: [
                      for (final d in s.found)
                        Card(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: ListTile(
                            leading: const CircleAvatar(
                              backgroundColor: Color(0xFFE0F2F1),
                              child: Icon(Icons.mic, color: Colors.teal),
                            ),
                            title: Text('X Note · ${d.sn}'),
                            subtitle: Text('MAC ${d.mac}    RSSI ${d.rssi}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () {
                              dev.connect(d); // 不 await:DeviceScreen 反应式显示阶段
                              Navigator.push(
                                context,
                                MaterialPageRoute(builder: (_) => const DeviceScreen()),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: scanning ? null : dev.startScan,
        icon: const Icon(Icons.bluetooth_searching),
        label: Text(scanning ? '扫描中…' : '扫描'),
      ),
    );
  }
}
