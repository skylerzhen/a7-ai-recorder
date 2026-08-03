import 'dart:async';

import 'package:a7_protocol/a7_protocol.dart';

import 'transport.dart';

/// 无界实时流假传输:把样本字节**循环推、永不结束**,模拟「录音中」的 B0B3 无界流。
/// 供模拟器 fail-fast 验证无界播放器架构(真机 B0B3 同样是无界流)。
class FakeUnboundedTransport implements BleTransport {
  FakeUnboundedTransport({
    required this.realtimeBytes,
    this.chunk = 200,
    this.tick = const Duration(milliseconds: 50), // 200B/50ms ≈ 4KB/s 真实时
  });

  final List<int> realtimeBytes;
  final int chunk;
  final Duration tick;

  final _cmd = StreamController<List<int>>.broadcast();
  final _rt = StreamController<List<int>>.broadcast();
  final _file = StreamController<List<int>>.broadcast();
  Timer? _timer;
  int _pos = 0;
  bool _connected = false;

  @override
  Stream<A7Scan> scan() async* {
    yield const A7Scan(
      deviceId: 'FAKE-UNBOUNDED',
      mac: '50:c0:f0:13:d4:c2',
      sn: 'FA9HA00666',
      rssi: -50,
    );
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    _connected = true;
    _timer?.cancel();
    _timer = Timer.periodic(tick, (_) {
      if (_rt.isClosed || realtimeBytes.isEmpty) return;
      final out = List<int>.filled(chunk, 0);
      for (int i = 0; i < chunk; i++) {
        out[i] = realtimeBytes[_pos];
        _pos = (_pos + 1) % realtimeBytes.length; // 循环,永不结束
      }
      _rt.add(out);
    });
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
    _timer?.cancel();
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
    _cmd.add(buildFrame(f.cmd, const [0x00])); // 无界 Demo 只关心实时流,其它回成功
  }

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    await _cmd.close();
    await _rt.close();
    await _file.close();
  }

  bool get isConnected => _connected;
}
