// just_audio 把 StreamAudioSource/Response 标为 @experimental(API 稳定可用,仅注解)。
// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:a7_protocol/a7_protocol.dart';

/// 无界实时 MP3 源(live-radio 式),供 B0B3 边录边播。
///
/// 与 Demo 版的根本区别:**不依赖已知总长**(`sourceLength=null`、不可 seek)——真机 B0B3
/// 是录音中的无界流。收到的字节进一个**有界环形缓冲**;一旦有播放器在拉流就即时出数,
/// 缓冲超过 [maxBufferMs] 时**按 MP3 帧边界丢最旧整帧**(直播延迟优先于完整),因此源端
/// 缓冲有上界、不随时长增长。
///
/// 选型理由:① MP3 帧自同步,ExoPlayer 原生支持无界 MP3 流(互联网电台同理);
/// ② ConcatenatingAudioSource 在 just_audio 0.10 已弃用;③ PCM 需原生 MediaCodec、超范围
/// 且破坏 a7_protocol 零依赖。已知局限:ExoPlayer 默认起播缓冲≈2.5s,端到端延迟≈2.5s
/// (要再低需自定义 LoadControl 或走 PCM,见 M3-gate 报告)。
class LiveMp3Source extends StreamAudioSource {
  LiveMp3Source({
    this.maxBufferMs = 4000,
    this.fallbackBytesPerSec = 4000,
  });

  /// 源端环形缓冲上界(毫秒);超出按帧丢最旧。
  final int maxBufferMs;

  /// 未解析出比特率前的字节率兜底(32kbps≈4000B/s)。
  final int fallbackBytesPerSec;

  final List<int> _ring = <int>[];
  int _bitrateBps = 0;
  int _droppedFrames = 0;
  int _releasedBytes = 0;
  int _peakRing = 0;
  StreamController<List<int>>? _out;
  bool _closed = false;

  // —— 指标(供日志证明源端缓冲有界)——
  int get bufferedBytes => _ring.length;
  int get droppedFrames => _droppedFrames;
  int get releasedBytes => _releasedBytes;
  int get peakRingBytes => _peakRing;
  int get bitrateBps => _bitrateBps;

  int get _bytesPerSec =>
      _bitrateBps > 0 ? _bitrateBps ~/ 8 : fallbackBytesPerSec;
  int get maxBufferBytes => (_bytesPerSec * maxBufferMs) ~/ 1000;

  /// 喂入实时字节(B0B3)。
  void add(List<int> bytes) {
    if (_closed) return;
    _ring.addAll(bytes);
    if (_bitrateBps == 0 && _ring.length >= 4) {
      _bitrateBps = mp3BitrateBps(_ring.sublist(0, 4));
    }
    // 背压:超界则按帧丢最旧(无在拉流时也生效,防止源端无限堆积)。
    while (_ring.length > maxBufferBytes) {
      final len = _ring.length >= 4 ? mp3FrameLength(_ring.sublist(0, 4)) : 0;
      final drop = len > 0 ? len : _ring.length;
      _ring.removeRange(0, drop > _ring.length ? _ring.length : drop);
      _droppedFrames++;
    }
    if (_ring.length > _peakRing) _peakRing = _ring.length;
    _flush();
  }

  void _flush() {
    final out = _out;
    if (out == null || out.isClosed) return;
    if (_ring.isNotEmpty) {
      out.add(List<int>.from(_ring));
      _releasedBytes += _ring.length;
      _ring.clear();
    }
    if (_closed && !out.isClosed) out.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _out?.close();
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    await _out?.close();
    final out = StreamController<List<int>>();
    _out = out;
    scheduleMicrotask(_flush); // 先吐已缓冲的部分
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: null,
      offset: start ?? 0,
      stream: out.stream,
      contentType: 'audio/mpeg',
    );
  }
}
