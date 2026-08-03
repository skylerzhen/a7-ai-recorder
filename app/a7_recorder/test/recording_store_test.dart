import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'package:a7_recorder/library/recording.dart';
import 'package:a7_recorder/library/recording_store.dart';

/// 把 path_provider 的文档目录指到临时目录,让 store 在单测里能真落盘/真删盘。
class _TmpPathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _TmpPathProvider(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
}

Recording _rec(String id, String path) => Recording(
      id: id,
      source: RecSource.live,
      audioPath: path,
      title: '会议$id',
      durationMs: 1000,
      status: RecStatus.done,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(ProviderContainer, RecordingStore)> freshStore() async {
    final tmp = await Directory.systemTemp.createTemp('rec_store_test');
    PathProviderPlatform.instance = _TmpPathProvider(tmp.path);
    final container = ProviderContainer();
    final store = container.read(recordingStoreProvider.notifier);
    // 让初始 _load(此时无索引文件,是 no-op)settle,避免与后续 add/remove 抢 state。
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return (container, store);
  }

  test('remove:真删磁盘 audioPath 文件 + 移除索引', () async {
    final (container, store) = await freshStore();
    addTearDown(container.dispose);

    final path = await store.saveAudioBytes('m1', const [1, 2, 3, 4]);
    expect(File(path).existsSync(), isTrue, reason: '落盘后文件应存在');
    await store.add(_rec('m1', path));

    await store.remove('m1');

    expect(File(path).existsSync(), isFalse, reason: 'remove 必须删掉磁盘文件');
    expect(container.read(recordingStoreProvider).any((r) => r.id == 'm1'), isFalse);
  });

  test('remove:audioPath 文件不存在也不崩(容错)', () async {
    final (container, store) = await freshStore();
    addTearDown(container.dispose);

    await store.add(_rec('ghost', '/no/such/dir/ghost.mp3'));
    await store.remove('ghost'); // 不应抛

    expect(container.read(recordingStoreProvider).any((r) => r.id == 'ghost'), isFalse);
  });

  test('clearAll:删全部音频文件 + 清索引', () async {
    final (container, store) = await freshStore();
    addTearDown(container.dispose);

    final p1 = await store.saveAudioBytes('a', const [1, 2]);
    final p2 = await store.saveAudioBytes('b', const [3, 4]);
    await store.add(_rec('a', p1));
    await store.add(_rec('b', p2));

    await store.clearAll();

    expect(File(p1).existsSync(), isFalse);
    expect(File(p2).existsSync(), isFalse);
    expect(container.read(recordingStoreProvider), isEmpty);
  });
}
