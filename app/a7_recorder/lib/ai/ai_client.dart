import 'dart:convert';

import 'package:http/http.dart' as http;

import 'ai_models.dart';

/// 调薄后端 POST /process(multipart 上传音频字节)。错误显式上抛,不吞。
class AiClient {
  /// [bytes] 音频文件字节(A7 录音=MP3);[filename] 仅用于后端识别后缀。
  static Future<AiResult> process({
    required String baseUrl,
    required List<int> bytes,
    required String filename,
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/process');
    final req = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes('audio', bytes, filename: filename));

    final streamed = await req.send().timeout(timeout);
    final resp = await http.Response.fromStream(streamed);
    final body = utf8.decode(resp.bodyBytes);

    if (resp.statusCode != 200) {
      String msg = body;
      try {
        final j = jsonDecode(body);
        if (j is Map && j['error'] != null) msg = j['error'].toString();
      } catch (_) {}
      throw Exception('后端 ${resp.statusCode}:$msg');
    }
    return AiResult.fromJson(jsonDecode(body) as Map<String, dynamic>);
  }

  /// 会中问 AI:POST /ask(SSE)。逐 token 流式 yield「小抄」。错误显式抛,不吞。
  static Stream<String> ask({
    required String baseUrl,
    String? goal,
    String? clientBackground,
    required String transcript,
    required String question,
  }) async* {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/ask');
    final client = http.Client();
    try {
      final req = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode({
          'goal': goal,
          'clientBackground': clientBackground,
          'transcript': transcript,
          'question': question,
        });
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        String msg = body;
        try {
          final j = jsonDecode(body);
          if (j is Map && j['error'] != null) msg = j['error'].toString();
        } catch (_) {}
        throw Exception('后端 ${resp.statusCode}:$msg');
      }
      final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        final j = jsonDecode(data);
        if (j is Map && j['error'] != null) throw Exception(j['error'].toString());
        final t = (j is Map) ? j['token'] : null;
        if (t is String && t.isNotEmpty) yield t;
      }
    } finally {
      client.close();
    }
  }

  /// 会中主动提示:POST /advise(非流式)→ LiveCue。错误显式抛,不吞。
  static Future<({bool shouldPrompt, String cue, String rationale})> advise({
    required String baseUrl,
    String? goal,
    String? clientBackground,
    required String transcript,
  }) async {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/advise');
    final resp = await http
        .post(uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'goal': goal, 'clientBackground': clientBackground, 'transcript': transcript}))
        .timeout(const Duration(seconds: 20));
    final body = utf8.decode(resp.bodyBytes);
    if (resp.statusCode != 200) {
      String msg = body;
      try {
        final j = jsonDecode(body);
        if (j is Map && j['error'] != null) msg = j['error'].toString();
      } catch (_) {}
      throw Exception('后端 ${resp.statusCode}:$msg');
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    return (
      shouldPrompt: j['shouldPrompt'] == true,
      cue: (j['cue'] ?? '').toString(),
      rationale: (j['rationale'] ?? '').toString(),
    );
  }

  /// 会后纪要(流式):POST /summarize(SSE)。逐 token yield 可读 markdown。错误显式抛,不吞。
  static Stream<String> summarizeStream({
    required String baseUrl,
    required String transcript,
    String? goal,
    String? clientBackground,
  }) async* {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/summarize');
    final client = http.Client();
    try {
      final req = http.Request('POST', uri)
        ..headers['Content-Type'] = 'application/json'
        ..headers['Accept'] = 'text/event-stream'
        ..body = jsonEncode({'transcript': transcript, 'goal': goal, 'clientBackground': clientBackground});
      final resp = await client.send(req);
      if (resp.statusCode != 200) {
        final body = await resp.stream.bytesToString();
        String msg = body;
        try {
          final j = jsonDecode(body);
          if (j is Map && j['error'] != null) msg = j['error'].toString();
        } catch (_) {}
        throw Exception('后端 ${resp.statusCode}:$msg');
      }
      final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final data = line.substring(5).trim();
        if (data.isEmpty) continue;
        if (data == '[DONE]') break;
        final j = jsonDecode(data);
        if (j is Map && j['error'] != null) throw Exception(j['error'].toString());
        final t = (j is Map) ? j['token'] : null;
        if (t is String && t.isNotEmpty) yield t;
      }
    } finally {
      client.close();
    }
  }

  /// 探活:GET /health。
  static Future<Map<String, dynamic>> health(String baseUrl) async {
    final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/health');
    final resp = await http.get(uri).timeout(const Duration(seconds: 5));
    return jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
  }
}
