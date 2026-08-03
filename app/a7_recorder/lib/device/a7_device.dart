import 'dart:async';

import 'package:a7_protocol/a7_protocol.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ble/real_transport.dart';
import '../ble/transport.dart';
import 'a7_state.dart';

/// 传输层 provider。
/// **M2 = `RealTransport`(真机 flutter_blue_plus)**;无硬件回退改回 `FakeTransport()`。
/// 测试里用 `transportProvider.overrideWithValue(FakeTransport())` 注入假传输。
final transportProvider = Provider<BleTransport>((ref) {
  final BleTransport t = RealTransport();
  ref.onDispose(() => t.dispose());
  return t;
});

final a7Provider = NotifierProvider<A7Device, A7State>(A7Device.new);

/// 设备控制器:扫描 → 连接 → 绑定(尽早,5s 内)→ 就绪 → requestMtu → 设备信息 / 文件列表。
class A7Device extends Notifier<A7State> {
  late final BleTransport _t;
  StreamSubscription<A7Scan>? _scanSub;

  @override
  A7State build() {
    _t = ref.read(transportProvider);
    ref.onDispose(() => _scanSub?.cancel());
    return const A7State();
  }

  Future<void> startScan() async {
    state = const A7State(phase: A7Phase.scanning);
    await _scanSub?.cancel();
    _scanSub = _t.scan().listen(
      (s) {
        if (!state.found.any((e) => e.deviceId == s.deviceId)) {
          state = state.copyWith(found: [...state.found, s]);
        }
      },
      // 真机:权限被拒 / 蓝牙未开 / 扫描出错 → 显示错误(M2 新增,Fake 不会触发)
      onError: (Object e) {
        state = state.copyWith(phase: A7Phase.error, error: '$e');
      },
    );
  }

  Future<void> connect(A7Scan scan) async {
    try {
      await _scanSub?.cancel();
      await _t.stopScan();
      state = state.copyWith(
          phase: A7Phase.connecting, device: scan, clearError: true);
      await _t.connect(scan.deviceId);

      // ⚠️ requestMtu 必须在绑定【之前】:绑定帧 24B 超过默认 MTU(23)的无响应写上限(20B)。
      // 实测 requestMtu 很快,connect→绑定仍稳落 5 秒内(任务书建议"绑定后再 MTU"在本设备不成立)。
      await _t.requestMtu(247);

      state = state.copyWith(phase: A7Phase.binding);
      final reply = await _request(bind('183396'.codeUnits), cmdBind);
      if (reply.data.isEmpty || reply.data[0] != 0x00) {
        throw StateError('绑定失败: ${reply.data}');
      }
      state = state.copyWith(phase: A7Phase.ready);

      await refreshInfo();
      await loadFiles();
    } catch (e) {
      state = state.copyWith(phase: A7Phase.error, error: '$e');
    }
  }

  Future<void> refreshInfo() async {
    final f = await _request(getDeviceInfo(), cmdDeviceInfo);
    state = state.copyWith(info: decodeDeviceInfo(f.data));
  }

  /// Wi-Fi 快传:发 0x1B 开 Soft AP 热点。回包 cmd 0x1B 且 data[0]==0x00 即成功。仅新机(X95-AINOTE)支持。
  Future<bool> startWifiAp() async {
    final f = await _request(openWifi(), cmdOpenWifi);
    return f.data.isNotEmpty && f.data[0] == 0x00;
  }

  /// 取热点 SSID/密码:发 0x02 触发设备在 b0b2 推 0x1F;3s 超时则用 SN 推导兜底。
  Future<WifiApInfo> fetchWifiInfo() async {
    final sn = state.device?.sn ?? '';
    final c = Completer<WifiApInfo>();
    late StreamSubscription<List<int>> sub;
    sub = _t.cmdReplies.listen((bytes) {
      final f = parseFrame(bytes);
      if (f.crcOk && f.cmd == cmdWifiInfo && !c.isCompleted) {
        c.complete(decodeWifiInfo(f.data));
      }
    });
    await _t.writeCommand(getBindInfo());
    try {
      return await c.future.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      if (sn.isNotEmpty) return wifiApFromSn(sn);
      rethrow;
    } finally {
      await sub.cancel();
    }
  }

  /// 0x0a:逐条收 status 0x00+条目,直到 0x02 结束(或 0x01 失败)。
  Future<void> loadFiles() async {
    final entries = <FileEntry>[];
    final done = Completer<void>();
    late StreamSubscription<List<int>> sub;
    sub = _t.cmdReplies.listen((bytes) {
      final f = parseFrame(bytes);
      if (!f.crcOk || f.cmd != cmdFileList) return;
      final status = f.data.isNotEmpty ? f.data[0] : 0x01;
      if (status == 0x00 && f.data.length > 1) {
        final e = decodeFileListEntry(f.data.sublist(1));
        if (!entries.any((x) => x.name == e.name)) entries.add(e); // 去重,防重复回包
      } else {
        if (!done.isCompleted) done.complete(); // 0x02 结束 / 0x01 失败
      }
    });
    await _t.writeCommand(listFiles());
    await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
    await sub.cancel();
    state = state.copyWith(files: entries);
  }

  /// 0x0b 取文件 → B0B4 重组 → 裁同步头 → 返回可播 MP3 字节。供「从 A7 拉取」入库。
  Future<List<int>> downloadFile(String name, {int expectedSize = 0}) async {
    FileReassembler? asm;
    final got = Completer<List<int>>();
    late StreamSubscription<List<int>> cmdSub;
    late StreamSubscription<List<int>> fileSub;
    cmdSub = _t.cmdReplies.listen((bytes) {
      final f = parseFrame(bytes);
      if (f.crcOk && f.cmd == cmdGetFile) {
        final r = decodeGetFileReply(f.data);
        asm = FileReassembler(r.size > 0 ? r.size : expectedSize);
      }
    });
    fileSub = _t.fileData.listen((chunk) {
      final a = asm;
      if (a == null) return;
      a.addChunk(chunk);
      if (a.isComplete && !got.isCompleted) got.complete(a.bytes);
    });
    await _t.writeCommand(getFile(name, seek: 0));
    try {
      final bytes = await got.future.timeout(const Duration(seconds: 120));
      try {
        await _t.writeCommand(buildFrame(cmdStopFile)); // 0x0c 停取
      } catch (_) {}
      return trimToMp3Sync(bytes);
    } finally {
      await cmdSub.cancel();
      await fileSub.cancel();
    }
  }

  Future<void> disconnect() async {
    await _t.disconnect();
    state = const A7State();
  }

  /// 写一帧并等下一条匹配 cmd 的回包(带超时)。
  Future<Frame> _request(List<int> frame, int expectCmd,
      {Duration timeout = const Duration(seconds: 3)}) async {
    final c = Completer<Frame>();
    late StreamSubscription<List<int>> sub;
    sub = _t.cmdReplies.listen((bytes) {
      final f = parseFrame(bytes);
      if (f.crcOk && f.cmd == expectCmd && !c.isCompleted) {
        c.complete(f);
        sub.cancel();
      }
    });
    await _t.writeCommand(frame);
    return c.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw TimeoutException('cmd 0x${expectCmd.toRadixString(16)} 无回复');
    });
  }
}
