import 'dart:async';

import 'package:a7_protocol/a7_protocol.dart';

import 'transport.dart';

/// 回放真机字节的假传输,用于无硬件开发/测试。
///
/// 行为尽量贴近真机 A7「X Note」:扫到一台设备、绑定回成功、设备信息回真 52B 帧、
/// 文件列表回若干条 + 结束。设备回包用 [buildFrame] 构造(小端 CRC,与真机一致)。
class FakeTransport implements BleTransport {
  final _cmd = StreamController<List<int>>.broadcast();
  final _rt = StreamController<List<int>>.broadcast();
  final _file = StreamController<List<int>>.broadcast();
  bool _connected = false;

  /// 真机抓到的 0x05 设备信息 52B(A7「X Note」,2026-06-17):
  /// 容量 60946/60931MB、充电中、电量 28、录音中、型号 xink_test、降噪 9、分段 3。
  static final List<int> deviceInfo52 = _hex(
    '0000ee120000ee03011c010100040101ff78696e6b5f746573740000'
    '000000000000000000000009ff0300000000000000000000',
  );

  @override
  Stream<A7Scan> scan() async* {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    yield const A7Scan(
      deviceId: '50:C0:F0:13:D4:C2',
      mac: '50:c0:f0:13:d4:c2',
      sn: 'FA9HA00666',
      rssi: -52,
    );
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<int> requestMtu(int mtu) async => 247;

  @override
  Stream<List<int>> get cmdReplies => _cmd.stream;

  @override
  Stream<List<int>> get realtime => _rt.stream;

  @override
  Stream<List<int>> get fileData => _file.stream;

  @override
  Future<void> writeCommand(List<int> frame) async {
    final f = parseFrame(frame);
    await Future<void>.delayed(const Duration(milliseconds: 60)); // 模拟 ~60ms 往返
    switch (f.cmd) {
      case cmdBind: // 0x03 绑定 -> 成功
        _cmd.add(buildFrame(cmdBind, const [0x00]));
        break;
      case cmdGetSn: // 0x01 -> 10B SN
        _cmd.add(buildFrame(cmdGetSn, 'FA9HA00666'.codeUnits));
        break;
      case cmdBindInfo: // 0x02 -> 已绑配对码
        _cmd.add(buildFrame(cmdBindInfo, '183396'.codeUnits));
        break;
      case cmdDeviceInfo: // 0x05 -> 真 52B
        _cmd.add(buildFrame(cmdDeviceInfo, deviceInfo52));
        break;
      case cmdFileList: // 0x0a -> 两条 + 结束(每条:status 0x00 + 名14 + 大小4大端 + 类型1)
        _cmd.add(buildFrame(cmdFileList, [0x00, ..._entry('REC0001.mp3', 1536000, 1)]));
        _cmd.add(buildFrame(cmdFileList, [0x00, ..._entry('CALL0007.mp3', 4096000, 0)]));
        _cmd.add(buildFrame(cmdFileList, const [0x02])); // 结束
        break;
      default:
        _cmd.add(buildFrame(f.cmd, const [0x00])); // 其它先回成功
    }
  }

  @override
  Future<void> dispose() async {
    await _cmd.close();
    await _rt.close();
    await _file.close();
  }

  bool get isConnected => _connected;

  static List<int> _entry(String name, int size, int type) {
    final n = List<int>.filled(14, 0);
    for (int i = 0; i < name.length && i < 14; i++) {
      n[i] = name.codeUnitAt(i);
    }
    return [
      ...n,
      (size >> 24) & 0xFF,
      (size >> 16) & 0xFF,
      (size >> 8) & 0xFF,
      size & 0xFF,
      type,
    ];
  }

  static List<int> _hex(String s) {
    final c = s.replaceAll(RegExp(r'\s'), '');
    return [for (int i = 0; i < c.length; i += 2) int.parse(c.substring(i, i + 2), radix: 16)];
  }
}
