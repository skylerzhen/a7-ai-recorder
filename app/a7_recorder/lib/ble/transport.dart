import 'package:a7_protocol/a7_protocol.dart';

/// 扫描到的 A7 设备(传输层在协议 [AdvInfo] 之上补 deviceId / rssi)。
class A7Scan {
  final String deviceId; // 平台地址:真传输 = BLE remoteId;假传输 = MAC
  final String mac;
  final String sn;
  final int rssi;
  const A7Scan({
    required this.deviceId,
    required this.mac,
    required this.sn,
    this.rssi = 0,
  });
}

/// App 依赖的 BLE 能力抽象。
///
/// 真机实现(M2)用 `flutter_blue_plus`;无硬件开发/测试用 [FakeTransport]。
/// 上层(设备控制器、UI)只依赖本接口,换实现零改动。
abstract class BleTransport {
  /// 按厂商号 0x1116 过滤,持续吐出扫到的 A7。
  Stream<A7Scan> scan();
  Future<void> stopScan();

  Future<void> connect(String deviceId);
  Future<void> disconnect();

  /// 连接后建议 requestMtu(247)。返回协商后的 MTU。
  Future<int> requestMtu(int mtu);

  /// B0B2 指令回复(设备 -> APP)。
  Stream<List<int>> get cmdReplies;

  /// B0B3 实时 MP3 流(设备 -> APP)。
  Stream<List<int>> get realtime;

  /// B0B4 文件 / 离线数据(设备 -> APP)。
  Stream<List<int>> get fileData;

  /// 写 B0B1(无响应)。传入用 [buildFrame] 构造好的整帧。
  Future<void> writeCommand(List<int> frame);

  Future<void> dispose();
}
