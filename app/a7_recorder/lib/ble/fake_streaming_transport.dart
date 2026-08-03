import 'dart:async';

import 'package:a7_protocol/a7_protocol.dart';

import 'transport.dart';

/// 流式假传输:用真机采样字节回放 B0B3 实时流 / B0B4 文件下载,供无硬件(模拟器)
/// 把音频管线跑起来。回放真字节,不造合成数据。
///
/// - 实时流:连上即按 [realtimeChunk]/[realtimeTick](默认 200B/50ms≈4KB/s,真实时节奏)
///   把 [realtimeBytes] 推到 [realtime]。
/// - 文件:收到 0x0b 取文件 → [cmdReplies] 回 `0x0b + size(4B 大端=文件总长)` → 从请求的
///   seek 处按 [fileChunk]/[fileTick] 把 [fileBytes] 推到 [fileData],支持断点续传。
class FakeStreamingTransport implements BleTransport {
  FakeStreamingTransport({
    required this.fileBytes,
    required this.realtimeBytes,
    this.realtimeChunk = 200,
    this.realtimeTick = const Duration(milliseconds: 50),
    this.fileChunk = 243,
    this.fileTick = const Duration(milliseconds: 3),
  });

  final List<int> fileBytes;
  final List<int> realtimeBytes;
  final int realtimeChunk;
  final Duration realtimeTick;
  final int fileChunk;
  final Duration fileTick;

  final _cmd = StreamController<List<int>>.broadcast();
  final _rt = StreamController<List<int>>.broadcast();
  final _file = StreamController<List<int>>.broadcast();

  bool _connected = false;
  bool _disposed = false;

  @override
  Stream<A7Scan> scan() async* {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    yield const A7Scan(
      deviceId: 'FAKE-STREAM',
      mac: '50:c0:f0:13:d4:c2',
      sn: 'FA9HA00666',
      rssi: -50,
    );
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    _connected = true;
    // 模拟「录音中」:一连上就自动推实时流。
    unawaited(_emit(_rt, realtimeBytes, realtimeChunk, realtimeTick));
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
    switch (f.cmd) {
      case cmdGetFile:
        final seek = _seekOf(f.data);
        final size = fileBytes.length;
        // 0x0b 回包:status(0) + 总大小(4B 大端)
        _cmd.add(buildFrame(cmdGetFile, <int>[
          0x00,
          (size >> 24) & 0xFF,
          (size >> 16) & 0xFF,
          (size >> 8) & 0xFF,
          size & 0xFF,
        ]));
        // 略等(模拟设备应答→出数延迟)后从 seek 处推文件字节。
        unawaited(() async {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await _emit(
            _file,
            seek < fileBytes.length ? fileBytes.sublist(seek) : const <int>[],
            fileChunk,
            fileTick,
          );
        }());
        break;
      case cmdBind:
        _cmd.add(buildFrame(cmdBind, const [0x00]));
        break;
      default:
        _cmd.add(buildFrame(f.cmd, const [0x00]));
    }
  }

  /// getFile 请求体:name(14) + seek(4,小端)。
  static int _seekOf(List<int> data) {
    if (data.length < 18) return 0;
    return data[14] | (data[15] << 8) | (data[16] << 16) | (data[17] << 24);
  }

  Future<void> _emit(
    StreamController<List<int>> ctl,
    List<int> data,
    int chunk,
    Duration tick,
  ) async {
    for (int i = 0; i < data.length; i += chunk) {
      if (_disposed || ctl.isClosed) return;
      final end = (i + chunk) > data.length ? data.length : i + chunk;
      ctl.add(data.sublist(i, end));
      if (tick > Duration.zero) await Future<void>.delayed(tick);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await _cmd.close();
    await _rt.close();
    await _file.close();
  }

  bool get isConnected => _connected;
}
