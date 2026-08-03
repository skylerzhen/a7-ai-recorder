import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// 后端 /stream WebSocket 推回的一条消息。
class CaptionMsg {
  final String type; // ready / transcript / status / error / done
  final String text;
  final String speaker;
  final bool isFinal;
  final int? startMs;
  final int? endMs;
  final int? frames;
  final String? status;
  final String? detail;
  final String? error;

  const CaptionMsg({
    required this.type,
    this.text = '',
    this.speaker = '',
    this.isFinal = false,
    this.startMs,
    this.endMs,
    this.frames,
    this.status,
    this.detail,
    this.error,
  });

  factory CaptionMsg.fromJson(Map<String, dynamic> j) => CaptionMsg(
        type: j['type'] as String? ?? '',
        text: j['text'] as String? ?? '',
        speaker: j['speaker'] as String? ?? '',
        isFinal: j['isFinal'] as bool? ?? false,
        startMs: (j['startMs'] as num?)?.toInt(),
        endMs: (j['endMs'] as num?)?.toInt(),
        frames: (j['frames'] as num?)?.toInt(),
        status: j['status'] as String?,
        detail: j['detail'] as String?,
        error: j['error'] as String?,
      );
}

/// 连后端 /stream:转发音频二进制(A7 B0B3 是 MP3 分片),收字幕 JSON。
class CaptionClient {
  final WebSocketChannel _ch;
  CaptionClient._(this._ch);

  static CaptionClient connect(String wsUrl) =>
      CaptionClient._(WebSocketChannel.connect(Uri.parse(wsUrl)));

  Stream<CaptionMsg> get messages => _ch.stream.map((d) {
        final s = d is String ? d : utf8.decode(d as List<int>);
        return CaptionMsg.fromJson(jsonDecode(s) as Map<String, dynamic>);
      });

  /// 发音频分片(二进制)。
  void sendAudio(List<int> bytes) {
    try {
      _ch.sink.add(bytes);
    } catch (_) {/* ignore */}
  }

  /// 发「结束」文本帧。
  void end() {
    try {
      _ch.sink.add('end');
    } catch (_) {/* ignore */}
  }

  Future<void> close() async {
    try {
      await _ch.sink.close();
    } catch (_) {/* ignore */}
  }
}
