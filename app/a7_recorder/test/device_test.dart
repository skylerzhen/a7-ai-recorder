import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/ble/fake_transport.dart';
import 'package:a7_recorder/device/a7_device.dart';
import 'package:a7_recorder/device/a7_state.dart';

void main() {
  test('controller drives FakeTransport to ready: decoded info + 2 files', () async {
    // 生产用 RealTransport;测试用 override 注入 FakeTransport(不碰真蓝牙)
    final container = ProviderContainer(overrides: [
      transportProvider.overrideWithValue(FakeTransport()),
    ]);
    addTearDown(container.dispose);
    final dev = container.read(a7Provider.notifier);

    // 扫描
    await dev.startScan();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final found = container.read(a7Provider).found;
    expect(found, isNotEmpty);
    expect(found.first.sn, 'FA9HA00666');
    expect(found.first.mac, '50:c0:f0:13:d4:c2');

    // 连接 → 绑定 → 设备信息 → 文件列表
    await dev.connect(found.first);
    final s = container.read(a7Provider);
    expect(s.phase, A7Phase.ready);
    expect(s.error, isNull);

    expect(s.info, isNotNull);
    expect(s.info!.totalMb, 60946);
    expect(s.info!.battery, 28);
    expect(s.info!.recording, 1);
    expect(s.info!.model, 'xink_test');

    expect(s.files.length, 2);
    expect(s.files[0].name, 'REC0001.mp3');
    expect(s.files[0].size, 1536000);
    expect(s.files[0].type, 1);
    expect(s.files[1].name, 'CALL0007.mp3');
  });
}
