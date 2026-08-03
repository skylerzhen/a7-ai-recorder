import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import 'recording.dart';

/// MP3 32kbps ≈ 4000 B/s = 4 B/ms → 由字节数估时长(列表展示用,播放器以实际为准)。
int mp3DurationMsFromBytes(int bytes) => (bytes / 4).round();

final recordingStoreProvider =
    NotifierProvider<RecordingStore, List<Recording>>(RecordingStore.new);

/// 录音库持久化(JSON 文件 + 音频落盘到文档目录)。本期不接云。
class RecordingStore extends Notifier<List<Recording>> {
  @override
  List<Recording> build() {
    _load(); // 异步加载,完成后刷新 state
    return const [];
  }

  Future<File> _indexFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/recordings.json');
  }

  Future<Directory> _audioDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final d = Directory('${dir.path}/recordings');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _load() async {
    try {
      final f = await _indexFile();
      if (await f.exists()) {
        final list = jsonDecode(await f.readAsString()) as List;
        state = list
            .map((e) => Recording.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {/* 损坏则忽略,从空开始 */}
  }

  Future<void> _save() async {
    final f = await _indexFile();
    await f.writeAsString(jsonEncode(state.map((r) => r.toJson()).toList()));
  }

  /// 把音频字节落盘,返回路径。
  Future<String> saveAudioBytes(String id, List<int> bytes, {String ext = 'mp3'}) async {
    final d = await _audioDir();
    final f = File('${d.path}/$id.$ext');
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  Future<void> add(Recording r) async {
    state = [r, ...state];
    await _save();
  }

  Future<void> update(Recording r) async {
    state = [for (final x in state) if (x.id == r.id) r else x];
    await _save();
  }

  /// 删除一场会议:先移除索引(列表即时收起)→ 再删磁盘音频文件(容错:不存在/失败都不崩)→ 落盘。
  Future<void> remove(String id) async {
    final rec = byId(id);
    state = state.where((r) => r.id != id).toList();
    if (rec != null) await _deleteAudio(rec.audioPath);
    await _save();
  }

  /// 清空:删全部音频文件 + 清索引(备「设置」棒用)。
  Future<void> clearAll() async {
    final all = state;
    state = const [];
    for (final r in all) {
      await _deleteAudio(r.audioPath);
    }
    await _save();
  }

  /// 删一个音频文件;容错:文件不存在或删除失败都不抛(残留不致命)。
  Future<void> _deleteAudio(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {/* 忽略 */}
  }

  Recording? byId(String id) {
    for (final r in state) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// 内置真 A7 样本入库(无硬件也能 demo;音频源=真 A7 离线下载的录音)。
  Future<Recording> addBuiltinSample() async {
    final id = 'sample-${DateTime.now().millisecondsSinceEpoch}';
    final data = await rootBundle.load('assets/downloaded.mp3');
    final bytes = data.buffer.asUint8List();
    final path = await saveAudioBytes(id, bytes);
    final r = Recording(
      id: id,
      source: RecSource.sample,
      audioPath: path,
      title: '真 A7 样本录音',
      durationMs: mp3DurationMsFromBytes(bytes.length),
      status: RecStatus.unprocessed,
      createdAt: DateTime.now(),
    );
    await add(r);
    return r;
  }

  /// 用户从本地导入的音频入库(RecSource.upload)。保留原扩展名供播放器识别。
  Future<Recording> addUpload({
    required String name,
    required List<int> bytes,
    String ext = 'mp3',
  }) async {
    final id = 'up-${DateTime.now().millisecondsSinceEpoch}';
    final path = await saveAudioBytes(id, bytes, ext: ext);
    final r = Recording(
      id: id,
      source: RecSource.upload,
      audioPath: path,
      title: name,
      durationMs: mp3DurationMsFromBytes(bytes.length),
      status: RecStatus.unprocessed,
      createdAt: DateTime.now(),
    );
    await add(r);
    return r;
  }

  /// 从设备下载的录音入库(BLE getFile 或 Wi-Fi 快传共用)。保留原扩展名(新机=.opus)。
  Future<Recording> addDownloaded({
    required String name,
    required List<int> bytes,
  }) async {
    final id = 'dev-${DateTime.now().millisecondsSinceEpoch}';
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'mp3';
    final path = await saveAudioBytes(id, bytes, ext: ext);
    final r = Recording(
      id: id,
      source: RecSource.device,
      audioPath: path,
      title: name,
      durationMs: mp3DurationMsFromBytes(bytes.length),
      status: RecStatus.unprocessed,
      createdAt: DateTime.now(),
    );
    await add(r);
    return r;
  }
}
