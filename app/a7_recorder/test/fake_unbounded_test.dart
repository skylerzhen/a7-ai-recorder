import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/ble/fake_unbounded_transport.dart';

// FakeUnboundedTransport 必须把样本循环推、永不结束 —— 收到的字节超过一整轮即证明无界。
void main() {
  final rt = File('assets/live_b3.mp3').readAsBytesSync();

  test('连上后无界循环推流(收到 > 2 整轮)', () async {
    final t = FakeUnboundedTransport(
      realtimeBytes: rt,
      chunk: 1000,
      tick: const Duration(milliseconds: 1),
    );
    int got = 0;
    final done = Completer<void>();
    final sub = t.realtime.listen((b) {
      got += b.length;
      if (got > rt.length * 2 && !done.isCompleted) done.complete();
    });
    await t.connect('x');
    await done.future.timeout(const Duration(seconds: 8));
    await sub.cancel();

    expect(got, greaterThan(rt.length * 2)); // 超过两整轮 → 确实在无界循环
    await t.dispose();
  });
}
