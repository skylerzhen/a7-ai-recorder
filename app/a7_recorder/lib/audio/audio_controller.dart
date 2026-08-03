import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:a7_protocol/a7_protocol.dart';

import '../ble/fake_streaming_transport.dart';
import '../ble/fake_unbounded_transport.dart';
import '../ble/transport.dart';
import 'live_mp3_source.dart';
import 'live_ogg_source.dart';

enum AudioPhase { idle, realtimePlaying, downloading, filePlaying, error }

class AudioState {
  final AudioPhase phase;
  final int received;
  final int total;
  final String? note;
  final String? error;

  const AudioState({
    this.phase = AudioPhase.idle,
    this.received = 0,
    this.total = 0,
    this.note,
    this.error,
  });

  double get progress => total == 0 ? 0 : (received / total).clamp(0, 1);

  AudioState copyWith({
    AudioPhase? phase,
    int? received,
    int? total,
    String? note,
    String? error,
    bool clearError = false,
  }) =>
      AudioState(
        phase: phase ?? this.phase,
        received: received ?? this.received,
        total: total ?? this.total,
        note: note ?? this.note,
        error: clearError ? null : (error ?? this.error),
      );
}

final audioControllerProvider =
    NotifierProvider<AudioController, AudioState>(AudioController.new);

/// 模拟器音频管线编排。
/// - 实时:`FakeUnboundedTransport`(无界循环流)→ `LiveMp3Source`(无界、有界缓冲、丢最旧)。
/// - 文件:`FakeStreamingTransport`(0x0b→B0B4)→ `FileReassembler` → 裁头 → 临时文件 → 播。
class AudioController extends Notifier<AudioState> {
  // 低延迟 LoadControl:压低 ExoPlayer 起播/最大缓冲,直播延迟优先。监听用的就是这个 _player 实例。
  // 实测抖动 p95 119ms / max 208ms,起播缓冲不低于 ~250ms 以防卡顿爆音;地板≈起播250+页60+抖动150≈0.5s。
  final AudioPlayer _player = AudioPlayer(
    audioLoadConfiguration: AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        minBufferDuration: const Duration(milliseconds: 500),
        maxBufferDuration: const Duration(milliseconds: 1500),
        bufferForPlaybackDuration: const Duration(milliseconds: 250),
        bufferForPlaybackAfterRebufferDuration: const Duration(milliseconds: 400),
        // 移除 targetBufferBytes:24KB < ExoPlayer 默认 64KB 分配块,会让缓冲判定到不了起播阈值→不解码无声。
        // 4KB/s 的 opus 流靠时长参数(min500/max1500/起播250)已足够控延迟,不需要再压字节阈值。
      ),
    ),
  );
  FakeStreamingTransport? _fileTransport;
  FakeUnboundedTransport? _unbounded;
  LiveMp3Source? _liveSource;
  LiveOggSource? _liveOgg; // 实时监听(新机 opus 路):无界 Ogg-Opus 源
  List<int>? _fileBytes;
  List<int>? _rtBytes;
  StreamSubscription<List<int>>? _rtSub;
  StreamSubscription<List<int>>? _cmdSub;
  StreamSubscription<List<int>>? _fileSub;
  Timer? _statsTimer;
  DateTime _lastProg = DateTime.fromMillisecondsSinceEpoch(0);
  AudioPlayer get player => _player;

  @override
  AudioState build() {
    ref.onDispose(() {
      _statsTimer?.cancel();
      _rtSub?.cancel();
      _cmdSub?.cancel();
      _fileSub?.cancel();
      _liveSource?.close();
      _liveOgg?.close();
      _player.dispose();
      _unbounded?.dispose();
      _fileTransport?.dispose();
    });
    return const AudioState();
  }

  Future<void> _stopAll() async {
    _statsTimer?.cancel();
    _statsTimer = null;
    await _rtSub?.cancel();
    await _cmdSub?.cancel();
    await _fileSub?.cancel();
    _rtSub = _cmdSub = _fileSub = null;
    await _liveSource?.close();
    _liveSource = null;
    await _liveOgg?.close(); // 实时监听 opus 路清理(无界 Ogg-Opus 源)
    _liveOgg = null;
    await _unbounded?.dispose();
    _unbounded = null;
    try {
      await _player.stop();
    } catch (_) {}
  }

  /// 「播放实时流」:无界循环流 → LiveMp3Source 边录边播,每秒记录缓冲深度(证明有界)。
  Future<void> playRealtime() async {
    try {
      await _stopAll();
      _rtBytes ??=
          (await rootBundle.load('assets/live_b3.mp3')).buffer.asUint8List();
      final t = FakeUnboundedTransport(realtimeBytes: _rtBytes!);
      _unbounded = t;
      final src = LiveMp3Source();
      _liveSource = src;
      state = const AudioState(phase: AudioPhase.realtimePlaying, note: '连接中…');

      _rtSub = t.realtime.listen(src.add);
      await t.connect('demo'); // 录音中:连上即无界推流
      await _player.setAudioSource(src);
      // ⚠️ 无界流:play() 的 Future 完成时机=播放结束,故永不返回,绝不能 await。
      unawaited(_player.play());
      state = state.copyWith(note: '边录边播(无界流)…');

      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final s = _liveSource;
        if (s == null) return;
        debugPrint('A7RT t=${_player.position.inSeconds}s buffer=${s.bufferedBytes}B '
            'peak=${s.peakRingBytes}B dropped=${s.droppedFrames}f '
            'released=${(s.releasedBytes / 1024).toStringAsFixed(0)}KB br=${s.bitrateBps}bps');
        state = state.copyWith(
          note: '边录边播(无界)· 缓冲 ${s.bufferedBytes}B · 峰值 ${s.peakRingBytes}B · 丢 ${s.droppedFrames} 帧',
        );
      });
    } catch (e) {
      state = AudioState(phase: AudioPhase.error, error: '$e');
    }
  }

  /// 「下载并播放文件」:0x0b → B0B4 重组 → 裁同步头 → 临时文件 → 播。进度按 100ms 节流。
  Future<void> downloadAndPlayFile() async {
    try {
      await _stopAll();
      _fileBytes ??=
          (await rootBundle.load('assets/downloaded.mp3')).buffer.asUint8List();
      await _fileTransport?.dispose();
      final t = FakeStreamingTransport(
        fileBytes: _fileBytes!,
        realtimeBytes: const <int>[],
      );
      _fileTransport = t;
      state = const AudioState(phase: AudioPhase.downloading, note: '请求文件 0x0b…');

      FileReassembler? asm;
      final completer = Completer<FileReassembler>();
      _cmdSub = t.cmdReplies.listen((bytes) {
        final f = parseFrame(bytes);
        if (f.crcOk && f.cmd == cmdGetFile) {
          final r = decodeGetFileReply(f.data);
          asm = FileReassembler(r.size);
          state = state.copyWith(total: r.size, note: '下载中 ${r.size}B…');
        }
      });
      _lastProg = DateTime.fromMillisecondsSinceEpoch(0);
      _fileSub = t.fileData.listen((chunk) {
        final a = asm;
        if (a == null) return;
        a.addChunk(chunk);
        final now = DateTime.now();
        if (now.difference(_lastProg).inMilliseconds >= 100 || a.isComplete) {
          _lastProg = now;
          state = state.copyWith(received: a.received, total: a.totalSize);
        }
        if (a.isComplete && !completer.isCompleted) completer.complete(a);
      });

      await t.writeCommand(getFile('REC0001.mp3', seek: 0));
      final done = await completer.future.timeout(const Duration(seconds: 60));
      await _cmdSub?.cancel();
      await _fileSub?.cancel();
      _cmdSub = _fileSub = null;

      final trimmed = trimToMp3Sync(done.bytes);
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/a7_download.mp3';
      await File(path).writeAsBytes(Uint8List.fromList(trimmed), flush: true);

      state = state.copyWith(
        phase: AudioPhase.filePlaying,
        received: done.received,
        note: '重组 ${done.received}B,裁前导 ${done.received - trimmed.length}B → 播放',
      );
      await _player.setFilePath(path);
      await _player.play();
    } catch (e) {
      state = AudioState(phase: AudioPhase.error, error: '$e');
    }
  }

  Future<void> stop() async {
    await _stopAll();
    state = const AudioState(phase: AudioPhase.idle, note: '已停止');
  }

  // ===== 真机路径(共享真传输,不在此销毁)=====

  String _recName() {
    final n = DateTime.now();
    String t2(int x) => x.toString().padLeft(2, '0');
    return '${t2(n.year % 100)}${t2(n.month)}${t2(n.day)}${t2(n.hour)}${t2(n.minute)}${t2(n.second)}';
  }

  /// 真机:0x06 开录 → 播真机 B0B3 实时流(无界 LiveMp3Source,边录边播)。
  Future<void> playDeviceRealtime(BleTransport transport) async {
    try {
      await _stopAll();
      final src = LiveMp3Source();
      _liveSource = src;
      state = const AudioState(phase: AudioPhase.realtimePlaying, note: '开始录音 0x06…');
      _rtSub = transport.realtime.listen(src.add); // 先订阅,别漏帧头
      await transport.writeCommand(startRecording(_recName(), 1));
      await _player.setAudioSource(src);
      unawaited(_player.play()); // 无界流不能 await
      state = state.copyWith(note: '边录边播(真机 B0B3)…');
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        final s = _liveSource;
        if (s == null) return;
        debugPrint('A7RT(real) t=${_player.position.inSeconds}s buffer=${s.bufferedBytes}B '
            'peak=${s.peakRingBytes}B dropped=${s.droppedFrames}f '
            'released=${(s.releasedBytes / 1024).toStringAsFixed(0)}KB br=${s.bitrateBps}bps');
        state = state.copyWith(
          note: '边录边播(真机)· 缓冲 ${s.bufferedBytes}B · 峰值 ${s.peakRingBytes}B · 丢 ${s.droppedFrames} 帧',
        );
      });
    } catch (e) {
      state = AudioState(phase: AudioPhase.error, error: '$e');
    }
  }

  /// 真机:停播 + 0x07 停录。
  Future<void> stopDevice(BleTransport transport) async {
    await _stopAll();
    try {
      await transport.writeCommand(stopRecording());
    } catch (_) {}
    state = const AudioState(phase: AudioPhase.idle, note: '已停录/停播');
  }

  /// 实时监听(边录边听)。opus=新机:88B Opus 流 → 逐页封 Ogg-Opus → just_audio
  /// (ExoPlayer/media3 原生解 Opus)边收边播,无 FFI/无原生解码;
  /// 否则旧机走现有 LiveMp3Source(MP3,逻辑零改动)。
  Future<void> startMonitor(BleTransport transport, {required bool opus}) async {
    if (!opus) {
      await playDeviceRealtime(transport); // 旧机 MP3 路,不动
      return;
    }
    try {
      await _stopAll();
      final src = LiveOggSource();
      _liveOgg = src;
      state = const AudioState(phase: AudioPhase.realtimePlaying, note: '开始录音 0x06…');
      // 先订阅再开录,别漏帧头;与 D2 转写并存(同一条 B0B3 广播流,各自订阅互不截断)。
      _rtSub = transport.realtime.listen(
        src.add,
        onError: (Object e) {
          state = AudioState(phase: AudioPhase.error, error: 'BLE 中断:$e');
          unawaited(stopMonitor(transport));
        },
      );
      await transport.writeCommand(startRecording(_recName(), 1)); // 0x06 开录
      await _player.setAudioSource(src);
      unawaited(_player.play()); // 无界流不能 await
      state = state.copyWith(note: '边录边听(Opus→Ogg · ExoPlayer 原生解码)…');
    } catch (e) {
      state = AudioState(phase: AudioPhase.error, error: '$e');
    }
  }

  /// 停监听(opus / mp3 通用)= 停播 + 0x07 停录。
  Future<void> stopMonitor(BleTransport transport) => stopDevice(transport);

  /// 真机:0x0b 取文件 → B0B4 重组 → 校验大小==声明 → 裁头 → 播。
  Future<void> downloadDeviceFile(BleTransport transport, String name,
      {int expectedSize = 0}) async {
    try {
      await _stopAll();
      state = AudioState(
          phase: AudioPhase.downloading, note: '请求 $name 0x0b…', total: expectedSize);
      FileReassembler? asm;
      final completer = Completer<FileReassembler>();
      _cmdSub = transport.cmdReplies.listen((bytes) {
        final f = parseFrame(bytes);
        if (f.crcOk && f.cmd == cmdGetFile) {
          final r = decodeGetFileReply(f.data);
          asm = FileReassembler(r.size > 0 ? r.size : expectedSize);
          state = state.copyWith(total: asm!.totalSize, note: '下载中 ${asm!.totalSize}B…');
        }
      });
      _lastProg = DateTime.fromMillisecondsSinceEpoch(0);
      _fileSub = transport.fileData.listen((chunk) {
        final a = asm;
        if (a == null) return;
        a.addChunk(chunk);
        final now = DateTime.now();
        if (now.difference(_lastProg).inMilliseconds >= 100 || a.isComplete) {
          _lastProg = now;
          state = state.copyWith(received: a.received, total: a.totalSize);
        }
        if (a.isComplete && !completer.isCompleted) completer.complete(a);
      });

      await transport.writeCommand(getFile(name, seek: 0));
      final done = await completer.future.timeout(const Duration(seconds: 120));
      await _cmdSub?.cancel();
      await _fileSub?.cancel();
      _cmdSub = _fileSub = null;
      try {
        await transport.writeCommand(buildFrame(cmdStopFile)); // 0x0c 停取
      } catch (_) {}

      final ok = done.received == done.totalSize;
      final trimmed = trimToMp3Sync(done.bytes);
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/a7_dl_${name.replaceAll(RegExp(r'[^A-Za-z0-9._]'), '_')}.mp3';
      await File(path).writeAsBytes(Uint8List.fromList(trimmed), flush: true);
      state = state.copyWith(
        phase: AudioPhase.filePlaying,
        received: done.received,
        note: '重组 ${done.received}B ${ok ? "== 声明 ✓" : "≠ 声明 ${done.totalSize}"} · 裁前导 ${done.received - trimmed.length}B → 播放',
      );
      await _player.setFilePath(path);
      unawaited(_player.play());
    } catch (e) {
      state = AudioState(phase: AudioPhase.error, error: '$e');
    }
  }
}
