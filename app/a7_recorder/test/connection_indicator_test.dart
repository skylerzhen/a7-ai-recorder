import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/device/a7_state.dart';
import 'package:a7_recorder/ui/connection_indicator.dart';

/// 覆盖 connViewOf:a7Provider 各 phase + 电量 → 指示器视图类别/文案。
void main() {
  test('idle → 未连接', () {
    expect(connViewOf(phase: A7Phase.idle, hasDevice: false).kind, ConnKind.disconnected);
  });

  test('scanning/connecting/binding → 连接中', () {
    for (final p in [A7Phase.scanning, A7Phase.connecting, A7Phase.binding]) {
      expect(connViewOf(phase: p, hasDevice: false).kind, ConnKind.connecting);
    }
  });

  test('ready + device + 电量充足 → 已连接(文案含电量)', () {
    final v = connViewOf(phase: A7Phase.ready, hasDevice: true, battery: 80);
    expect(v.kind, ConnKind.connected);
    expect(v.text, contains('80'));
  });

  test('ready + device + 电量<20 → 低电告警(文案含电量)', () {
    final v = connViewOf(phase: A7Phase.ready, hasDevice: true, battery: 12);
    expect(v.kind, ConnKind.lowBattery);
    expect(v.text, contains('12'));
  });

  test('ready + device 但 info 未到(battery=null)→ 已连接(无电量)', () {
    expect(connViewOf(phase: A7Phase.ready, hasDevice: true, battery: null).kind, ConnKind.connected);
  });

  test('ready 但无 device → 未连接', () {
    expect(connViewOf(phase: A7Phase.ready, hasDevice: false).kind, ConnKind.disconnected);
  });

  test('error → 连接异常', () {
    expect(connViewOf(phase: A7Phase.error, hasDevice: true).kind, ConnKind.error);
  });
}
