import 'dart:async';
import 'dart:io';

import 'package:a7_protocol/a7_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'ble_permissions.dart';
import 'transport.dart';

/// 真机 BLE 传输(flutter_blue_plus)。
///
/// 只做 BLE I/O —— 构帧 / 解析全部复用 `a7_protocol`,传输层不重写协议逻辑。
/// debug=true 时把 TX / B0B2 RX 打成 hex + 时序(A7BLE 前缀),供验收(绑定耗时、原始帧)。
class RealTransport implements BleTransport {
  static const bool debug = true;

  // B0B0 控制服务 + 四特征(16-bit base UUID 展开为 128-bit)
  static final _svc = Guid('0000b0b0-0000-1000-8000-00805f9b34fb');
  static final _chWrite = Guid('0000b0b1-0000-1000-8000-00805f9b34fb'); // write 无响应
  static final _chCmd = Guid('0000b0b2-0000-1000-8000-00805f9b34fb'); // notify 指令回复
  static final _chRt = Guid('0000b0b3-0000-1000-8000-00805f9b34fb'); // notify 实时 MP3
  static final _chFile = Guid('0000b0b4-0000-1000-8000-00805f9b34fb'); // notify 文件

  final _cmd = StreamController<List<int>>.broadcast();
  final _rt = StreamController<List<int>>.broadcast();
  final _file = StreamController<List<int>>.broadcast();
  final _scanCtl = StreamController<A7Scan>.broadcast();
  final _subs = <StreamSubscription<dynamic>>[];
  StreamSubscription<List<ScanResult>>? _scanResultsSub;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _writeCh;

  /// 连接建立的时刻 → 5 秒绑定窗口起点。
  final _sw = Stopwatch();

  void _log(String m) {
    if (debug) debugPrint('A7BLE +${_sw.isRunning ? _sw.elapsedMilliseconds : 0}ms: $m');
  }

  static String _hex(List<int> b) =>
      b.map((x) => (x & 0xFF).toRadixString(16).padLeft(2, '0')).join(' ');

  @override
  Stream<A7Scan> scan() {
    _startScan();
    return _scanCtl.stream;
  }

  Future<void> _startScan() async {
    _log('_startScan: 申请权限...');
    final perm = await ensureBlePermissions();
    if (!perm.granted) {
      _log('权限被拒: ${perm.message}');
      _scanCtl.addError(perm.message ?? '蓝牙权限不足');
      return;
    }
    final supported = await FlutterBluePlus.isSupported;
    _log('权限 OK;isSupported=$supported');
    if (!supported) {
      _scanCtl.addError('此设备不支持蓝牙');
      return;
    }
    // adapterStateNow 在未订阅时可能是 unknown(并非真的关着),这里主动 await 一个
    // 确定状态;只有明确 off 才中止(unknown/超时按"已开"处理,避免误拦)。
    final adapterState = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(const Duration(seconds: 3),
            onTimeout: () => BluetoothAdapterState.on);
    _log('adapterState=$adapterState');
    if (adapterState == BluetoothAdapterState.off) {
      _scanCtl.addError('蓝牙未打开,请先打开蓝牙后重试');
      return;
    }
    _scanResultsSub ??= FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final ad = r.advertisementData;
        // 诊断:打印每个「有名字或有厂商数据」的设备,看 A7 到底广播了什么
        if (debug && (ad.advName.isNotEmpty || ad.manufacturerData.isNotEmpty)) {
          final keys =
              ad.manufacturerData.keys.map((k) => '0x${k.toRadixString(16)}').toList();
          _log('SCAN name="${ad.advName}" msd=$keys rssi=${r.rssi} id=${r.device.remoteId.str}');
        }
        // 认厂商号 0x1116;payload = MAC(6)+SN(10),交 a7_protocol 解析
        final payload = ad.manufacturerData[kCompanyId];
        if (payload == null || payload.length < 16) continue;
        final info = parseFromBleak({kCompanyId: payload});
        if (info == null) continue;
        _scanCtl.add(A7Scan(
          deviceId: r.device.remoteId.str,
          mac: info.mac,
          sn: info.sn,
          rssi: r.rssi,
        ));
      }
    }, onError: (Object e) => _scanCtl.addError('扫描出错: $e'));

    _log('startScan(认厂商号 0x1116)');
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 20));
  }

  @override
  Future<void> stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
  }

  @override
  Future<void> connect(String deviceId) async {
    // 防止重连累积订阅(否则 notify 回调会重复触发,回包/文件列表翻倍)
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    final dev = BluetoothDevice.fromId(deviceId);
    _device = dev;
    _subs.add(dev.connectionState.listen((s) => _log('connectionState=$s')));

    _log('connect($deviceId)...');
    // mtu:null → 不在 connect 阶段自动协商 MTU,留到绑定成功后再 requestMtu,保住 5s 绑定窗口
    await dev.connect(timeout: const Duration(seconds: 10), mtu: null);
    _sw
      ..reset()
      ..start();
    _log('connected;发现服务...');

    final services = await dev.discoverServices();
    final svc = services.where((x) => x.uuid == _svc).toList();
    if (svc.isEmpty) {
      throw StateError('未找到 B0B0 控制服务(可能不是 A7 设备)');
    }
    final chars = svc.first.characteristics;
    BluetoothCharacteristic find(Guid u) => chars.firstWhere((c) => c.uuid == u);
    _writeCh = find(_chWrite);

    // ⚠️ 三路 notify 必须在发绑定前就绪,否则收不到 0x03 回包
    Future<void> sub(Guid u, StreamController<List<int>> ctl, String tag) async {
      final c = find(u);
      await c.setNotifyValue(true);
      _subs.add(c.onValueReceived.listen((v) {
        if (tag == 'B2') _log('RX $tag: ${_hex(v)}');
        ctl.add(v);
      }));
    }

    await sub(_chCmd, _cmd, 'B2');
    await sub(_chRt, _rt, 'B3');
    await sub(_chFile, _file, 'B4');
    _log('notify 就绪(B2/B3/B4)');
  }

  @override
  Future<int> requestMtu(int mtu) async {
    final d = _device;
    if (d == null) return 0;
    // iOS:requestMtu 是 android-only(系统在连接时已自动协商,现代 iPhone 通常 185+)。
    // 直接读当前协商值,不调那个会抛 `android-only` 的 API。绑定帧 24B 在 iOS 自动 MTU 下无碍。
    if (Platform.isIOS) {
      final got = d.mtuNow;
      _log('iOS mtuNow=$got(系统自动协商,跳过 android-only 的 requestMtu)');
      return got;
    }
    final got = await d.requestMtu(mtu);
    _log('requestMtu($mtu) → $got');
    return got;
  }

  @override
  Future<void> writeCommand(List<int> frame) async {
    final w = _writeCh;
    if (w == null) throw StateError('未连接,无法写指令');
    _log('TX: ${_hex(frame)}');
    await w.write(frame, withoutResponse: true);
  }

  @override
  Stream<List<int>> get cmdReplies => _cmd.stream;
  @override
  Stream<List<int>> get realtime => _rt.stream;
  @override
  Stream<List<int>> get fileData => _file.stream;

  @override
  Future<void> disconnect() async {
    try {
      await _device?.disconnect();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    await _scanResultsSub?.cancel();
    await disconnect();
    await _cmd.close();
    await _rt.close();
    await _file.close();
    await _scanCtl.close();
  }
}
