// just_audio 把 StreamAudioSource/Response 标为 @experimental(API 稳定可用,仅注解)。
// ignore_for_file: experimental_member_use
import 'dart:async';

import 'package:just_audio/just_audio.dart';

import 'ogg_opus_muxer.dart';

/// 无界实时 Ogg-Opus 源(边录边听,新机):B0B3 88B 记录流 → 逐页封 Ogg-Opus →
/// just_audio / ExoPlayer(media3)**原生解 Opus** 边收边播。无 FFI、无原生解码。
///
/// 与 [LiveMp3Source] 同构:头页(OpusHead/OpusTags)先发,音频页随到随封;`sourceLength=null`、不可 seek。
/// 每页 ~3 包(60ms),配合 AudioController 已压低的 ExoPlayer 起播缓冲(bufferForPlayback 250ms)。
/// 不丢页(Ogg 页序号必须连续;直播下播放器按实时消费,缓冲自然有界)。
class LiveOggSource extends StreamAudioSource {
  LiveOggSource({this.packetsPerPage = 3});

  /// 每页打包多少个 20ms 包(越小延迟越低、开销略高);3 包=60ms,压低成页前的攒包延迟。
  final int packetsPerPage;

  final OggOpusEncoder _enc = OggOpusEncoder();
  final List<int> _recBuf = <int>[]; // 跨片攒 88B 记录
  final List<int> _pending = <int>[]; // 待发的(头页 + 音频页)字节
  List<int>? _header;
  StreamController<List<int>>? _out;
  bool _closed = false;

  /// 喂入实时字节(B0B3 88B 记录流)。
  void add(List<int> bytes) {
    if (_closed) return;
    _recBuf.addAll(bytes);
    final packets = <List<int>>[];
    while (_recBuf.length >= 88) {
      packets.add(_recBuf.sublist(8, 88)); // [8:88] 80B Opus 包
      _recBuf.removeRange(0, 88);
    }
    if (packets.isEmpty) return;
    _header ??= _enc.header();
    for (var i = 0; i < packets.length; i += packetsPerPage) {
      final end = (i + packetsPerPage) > packets.length ? packets.length : i + packetsPerPage;
      _pending.addAll(_enc.audio(packets.sublist(i, end)));
    }
    _flush();
  }

  void _flush() {
    final out = _out;
    if (out == null || out.isClosed) return;
    if (_pending.isNotEmpty) {
      out.add(List<int>.from(_pending));
      _pending.clear();
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
    final hdr = _header ??= _enc.header();
    scheduleMicrotask(() {
      if (!out.isClosed) out.add(hdr); // 头页(OpusHead/OpusTags)必须最先
      _flush();
    });
    return StreamAudioResponse(
      rangeRequestsSupported: false,
      sourceLength: null,
      contentLength: null,
      offset: start ?? 0,
      stream: out.stream,
      contentType: 'audio/ogg',
    );
  }
}
