import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 卡上一个文件。
class WifiFile {
  final String name;
  final int size;
  final int type;
  const WifiFile({required this.name, required this.size, this.type = -1});
}

/// 设备本地 AP 快传 —— **真机端到端验通的最终协议**(2026-06-29;见 `wifi_fasttransfer/LOCAL_TRANSFER.md`)。
///
/// 裸 TCP `192.168.200.1:8475`(设备 0x1B 开热点后即起,带重试)+ Xnote 魔术帧:
/// `"XnoteWifiHead  "(15B) | cmd(1) | short(2) | short(2) | int32-BE(payloadLen) | payload | "XnoteWifiTail   "(16B)`。
/// **全大端(BE)**。收方向 `indexOf("XnoteWifiHead")` 定位 + 用 len 切帧(payload 可能含魔术字节,不靠搜 tail)。
///
/// 命令(cmd_3085s):getFiles=10(列清单)· startSyncFile=11(下载)· endSyncFile=12。
/// 坑:getFiles 首帧 cmd=0x20(会话 ack,直接按 cmd 过滤忽略)。
class WifiSocketClient {
  static const String host = '192.168.200.1';
  static const int port = 8475;

  static final List<int> _head = utf8.encode('XnoteWifiHead  '); // 15B(发送)
  static final List<int> _tail = utf8.encode('XnoteWifiTail   '); // 16B(发送)
  static final List<int> _headMark = utf8.encode('XnoteWifiHead'); // 13B(收:定位帧头)
  static const int _hdrLen = 15 + 1 + 2 + 2 + 4; // head15 + cmd1 + short2 + short2 + len4 = 24
  static const int _tailLen = 16;

  static const int cmdGetFiles = 10;
  static const int cmdStartSync = 11;
  static const int cmdEndSync = 12;
  static const int _nameLen = 14; // 定长文件名(同 BLE 0x0a)

  Socket? _sock;
  final List<int> _buf = [];
  final StreamController<({int cmd, List<int> payload})> _frames = StreamController.broadcast();

  /// 连 8475(openWifi 后即起 → 重试 4 次 / 每次 2s)。
  Future<void> connect({int retries = 4}) async {
    for (var i = 0; i < retries; i++) {
      try {
        _sock = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
        _sock!.listen(_onData, onError: (_) {}, cancelOnError: false);
        return;
      } catch (_) {
        if (i == retries - 1) rethrow;
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> close() async {
    try {
      await _sock?.close();
    } catch (_) {}
    _sock?.destroy();
    _sock = null;
    if (!_frames.isClosed) await _frames.close();
  }

  /// 收:定位 head 魔术 → 读 len(BE)→ 用 len 切出整帧(robust:payload 含魔术也不误切)。
  void _onData(List<int> data) {
    _buf.addAll(data);
    while (true) {
      final h = _indexOf(_buf, _headMark, 0);
      if (h < 0) {
        if (_buf.length > 64) _buf.removeRange(0, _buf.length - 16); // 留可能的半个 head
        break;
      }
      if (h > 0) _buf.removeRange(0, h); // 丢 head 前垃圾,head 归零
      if (_buf.length < _hdrLen) break; // 头不全,等
      final cmd = _buf[15];
      final len = _readInt32(_buf, 20); // cmd@15, short@16, short@18, len@20
      final frameEnd = _hdrLen + len + _tailLen;
      if (_buf.length < frameEnd) break; // 整帧未到齐
      final payload = _buf.sublist(_hdrLen, _hdrLen + len);
      if (!_frames.isClosed) _frames.add((cmd: cmd, payload: payload));
      _buf.removeRange(0, frameEnd);
    }
  }

  List<int> _frame(int cmd, List<int> payload) {
    final b = BytesBuilder();
    b.add(_head);
    b.addByte(cmd & 0xFF);
    b.add(const [0, 0, 0, 0]); // 两个保留 short(0)
    b.add(_int32(payload.length));
    b.add(payload);
    b.add(_tail);
    return b.toBytes();
  }

  void _send(int cmd, List<int> payload) => _sock?.add(_frame(cmd, payload));

  /// 列清单:发 getFiles(10,空)。响应每条帧 = status(1) + name(14) + size(4 BE) + type(1);
  /// status=0x00 一条文件、0x02 列表结束(同 BLE 0x0a)。0x20 ack 帧按 cmd 过滤已忽略。
  Future<List<WifiFile>> listFiles({Duration timeout = const Duration(seconds: 10)}) async {
    final out = <WifiFile>[];
    final c = Completer<List<WifiFile>>();
    final sub = _frames.stream.where((f) => f.cmd == cmdGetFiles).listen((f) {
      var pos = 0;
      final p = f.payload;
      while (pos < p.length) {
        final status = p[pos];
        if (status == 0x02) {
          if (!c.isCompleted) c.complete(out);
          return;
        }
        if (status == 0x00 && pos + 1 + _nameLen + 4 + 1 <= p.length) {
          final nb = p.sublist(pos + 1, pos + 1 + _nameLen);
          final nul = nb.indexOf(0);
          final name = String.fromCharCodes(nul >= 0 ? nb.sublist(0, nul) : nb).trim();
          final size = _readInt32(p, pos + 1 + _nameLen);
          final type = p[pos + 1 + _nameLen + 4];
          if (name.isNotEmpty) out.add(WifiFile(name: name, size: size, type: type));
          pos += 1 + _nameLen + 4 + 1;
        } else {
          pos += 1; // 兜底前进,防死循环
        }
      }
    });
    _send(cmdGetFiles, const []);
    try {
      return await c.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }

  /// 下载:发 startSyncFile(11,name(14 原始ASCII)+offset(4 BE,0))。
  /// 首个 cmd=11 帧 payload = status(1)+size(4 BE);之后 cmd=11 帧 payload = 纯文件字节块,累加到 size;收完发 endSyncFile(12)。
  Future<List<int>> download(
    String name,
    int sizeHint, {
    void Function(int received, int total)? onProgress,
    Duration idle = const Duration(seconds: 20),
  }) async {
    final out = <int>[];
    var total = sizeHint;
    var gotHeader = false;
    final done = Completer<List<int>>();
    Timer? idleTimer;
    void bump() {
      idleTimer?.cancel();
      idleTimer = Timer(idle, () {
        if (!done.isCompleted) done.completeError('下载超时(${idle.inSeconds}s 无数据)');
      });
    }

    final sub = _frames.stream.where((f) => f.cmd == cmdStartSync).listen((f) {
      final p = f.payload;
      if (!gotHeader) {
        gotHeader = true; // 首帧 = status(1) + size(4 BE)
        if (p.length >= 5) total = _readInt32(p, 1);
        bump();
        return;
      }
      out.addAll(p); // 数据帧 = 纯文件字节
      onProgress?.call(out.length, total);
      bump();
      if (total > 0 && out.length >= total && !done.isCompleted) {
        done.complete(out.sublist(0, total));
      }
    });
    bump();
    _send(cmdStartSync, <int>[..._padName(name), ..._int32(0)]);
    try {
      return await done.future;
    } finally {
      idleTimer?.cancel();
      await sub.cancel();
      _send(cmdEndSync, const []); // 收完通知结束
    }
  }

  static List<int> _padName(String name) {
    final raw = name.codeUnits.take(_nameLen).toList();
    return <int>[...raw, ...List.filled(_nameLen - raw.length, 0)];
  }

  static List<int> _int32(int v) =>
      [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]; // big-endian
  static int _readInt32(List<int> b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

  static int _indexOf(List<int> hay, List<int> needle, int from) {
    outer:
    for (var i = from; i + needle.length <= hay.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return -1;
  }
}
