import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../ai/ai_client.dart';
import '../ai/ai_models.dart';

/// AI 测试页:真 A7 录音(内置样本)→ 后端 → 一屏 dump 转写+纪要+原始。
///
/// 音频源 = 内置 assets/downloaded.mp3(A7 离线下载的真录音,设备来源)。
/// 「上传本地音频」次要路径待 file_picker 与 compileSdk(android-36)版本对齐后再加。
class AiTestScreen extends StatefulWidget {
  const AiTestScreen({super.key});

  @override
  State<AiTestScreen> createState() => _AiTestScreenState();
}

class _AiTestScreenState extends State<AiTestScreen> {
  // 真机默认填 Mac 的局域网 IP;模拟器用 10.0.2.2。
  final _urlCtl = TextEditingController(text: 'http://10.0.2.2:8787');

  bool _busy = false;
  String? _error;
  String? _status;
  AiResult? _result;

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  Future<void> _health() async {
    setState(() {
      _error = null;
      _status = '探活中…';
    });
    try {
      final h = await AiClient.health(_urlCtl.text.trim());
      setState(() => _status = '后端在线:$h');
    } catch (e) {
      setState(() {
        _status = null;
        _error = '探活失败:$e';
      });
    }
  }

  Future<void> _process() async {
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
      _result = null;
    });
    try {
      final data = await rootBundle.load('assets/downloaded.mp3');
      final bytes = data.buffer.asUint8List();
      setState(() => _status = '上传 ${bytes.length} B 处理中…（长录音可能数分钟）');
      final res = await AiClient.process(
        baseUrl: _urlCtl.text.trim(),
        bytes: bytes,
        filename: 'downloaded.mp3', // 真 A7 离线下载的录音样本(设备来源)
      );
      setState(() {
        _result = res;
        _status = '完成';
      });
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI 测试 · 转写+纪要')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlCtl,
            decoration: InputDecoration(
              labelText: '后端地址',
              helperText: '真机填 Mac 局域网 IP(如 http://192.168.x.x:8787);模拟器用 10.0.2.2',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(icon: const Icon(Icons.wifi_find), onPressed: _busy ? null : _health),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.memory, color: Colors.teal),
              title: const Text('音频源:真 A7 录音(内置样本)'),
              subtitle: const Text('downloaded.mp3 = A7 离线下载的真录音(设备来源)'),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _process,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_busy ? '处理中…' : '处理(转写+纪要)'),
          ),
          if (_status != null) ...[
            const SizedBox(height: 10),
            Text(_status!, style: const TextStyle(color: Colors.teal)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              color: const Color(0xFFFDECEA),
              child: Text('错误:$_error', style: const TextStyle(color: Colors.red)),
            ),
          ],
          if (_result != null) ...[
            const Divider(height: 32),
            ..._buildResult(_result!),
          ],
        ],
      ),
    );
  }

  List<Widget> _buildResult(AiResult r) {
    return [
      _h('转写(${r.transcript.length} 段)'),
      if (r.transcript.isEmpty) const Text('（空)', style: TextStyle(color: Colors.black54)),
      for (final s in r.transcript) _segTile(s),
      const SizedBox(height: 16),
      _h('纪要'),
      if (r.summary == null)
        const Text('（后端未生成结构化纪要,见下方原始 llmRaw/llmError）',
            style: TextStyle(color: Colors.orange))
      else
        _summary(r.summary!),
      const SizedBox(height: 16),
      _h('原始 / 耗时'),
      _kv('timings', r.timings),
      if (r.summaryMarkdown != null)
        ExpansionTile(
          title: const Text('summaryMarkdown'),
          childrenPadding: const EdgeInsets.all(8),
          children: [
            SelectableText(r.summaryMarkdown!, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ExpansionTile(
        title: const Text('raw JSON(asrEvents / llmRaw / asrError / llmError …)'),
        childrenPadding: const EdgeInsets.all(8),
        children: [
          SelectableText(
            _pretty(r.raw),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ],
      ),
    ];
  }

  static String _pretty(Object? o) {
    try {
      return const JsonEncoder.withIndent('  ').convert(o);
    } catch (_) {
      return '$o';
    }
  }

  Widget _segTile(AiTranscriptSeg s) {
    final ts = s.startMs != null
        ? '${(s.startMs! / 1000).toStringAsFixed(1)}–${s.endMs != null ? (s.endMs! / 1000).toStringAsFixed(1) : '?'}s'
        : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            margin: const EdgeInsets.only(right: 8, top: 2),
            decoration: BoxDecoration(
              color: s.speaker == '说话人1' ? const Color(0xFFE0F2F1) : const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(s.speaker, style: const TextStyle(fontSize: 11)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (ts.isNotEmpty || !s.isFinal)
                  Text('$ts  ${s.isFinal ? 'final' : 'interim'}',
                      style: TextStyle(fontSize: 10, color: s.isFinal ? Colors.black45 : Colors.orange)),
                Text(s.text),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summary(AiSummary s) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sub('叙事'),
          Text(s.narrative),
          _list('决定', s.decisions),
          _list('行动项', s.actionItems),
          _list('待解决', s.openQuestions),
          _list('收获', s.takeaways),
        ],
      );

  Widget _list(String title, List<String> items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sub('$title(${items.length})'),
          if (items.isEmpty)
            const Text('—', style: TextStyle(color: Colors.black54))
          else
            for (final i in items) Text('· $i'),
        ],
      );

  Widget _kv(String k, Object? v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Text('$k: ${_pretty(v)}', style: const TextStyle(fontSize: 12)),
      );

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.teal)),
      );

  Widget _sub(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
      );
}
