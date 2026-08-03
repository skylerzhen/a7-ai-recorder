import 'package:a7_protocol/a7_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../device/a7_device.dart';
import '../library/recording_store.dart';
import 'detail_screen.dart';

/// 设备文件列表:点一条 → 0x0b 下载重组 → 入库 → 进详情页。
class FilesScreen extends ConsumerWidget {
  const FilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(a7Provider).files;
    final dev = ref.read(a7Provider.notifier);
    final store = ref.read(recordingStoreProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: Text('从 A7 拉取 (${files.length})'),
        actions: [
          IconButton(tooltip: '刷新', icon: const Icon(Icons.refresh), onPressed: dev.loadFiles),
        ],
      ),
      body: files.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('暂无文件\n（录音中且无已保存文件时为空,先停录入盘;或点刷新）',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.black54)),
              ),
            )
          : ListView(
              children: [
                for (final f in files)
                  Card(
                    margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    child: ListTile(
                      leading: Icon(f.type == 0 ? Icons.call : Icons.sticky_note_2, color: Colors.teal),
                      title: Text(f.name),
                      subtitle: Text('${f.type == 0 ? '电话录音' : '笔记录音'}  ·  ${_size(f.size)}'),
                      trailing: const Icon(Icons.download_outlined),
                      onTap: () => _download(context, dev, store, f),
                    ),
                  ),
              ],
            ),
    );
  }

  Future<void> _download(
    BuildContext context,
    A7Device dev,
    RecordingStore store,
    FileEntry f,
  ) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 16),
            Expanded(child: Text('下载重组 ${f.name}…')),
          ],
        ),
      ),
    );
    try {
      final bytes = await dev.downloadFile(f.name, expectedSize: f.size);
      final rec = await store.addDownloaded(name: f.name, bytes: bytes);
      if (!context.mounted) return;
      Navigator.pop(context); // 关进度框
      Navigator.push(context, MaterialPageRoute(builder: (_) => DetailScreen(id: rec.id)));
    } catch (e) {
      if (!context.mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('下载失败:$e')));
    }
  }

  static String _size(int b) {
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(1)} KB';
    return '$b B';
  }
}
