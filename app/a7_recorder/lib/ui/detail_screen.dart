import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../ai/ai_client.dart';
import '../ai/ai_models.dart';
import '../ai/backend.dart';
import '../ai/summary_gen.dart';
import '../audio/ogg_opus_muxer.dart';
import '../library/recording.dart';
import '../library/recording_store.dart';
import '../library/segment_match.dart';

/// 详情页「三件套」:① 播放器(可拖动) ② 说话人转写(点段跳转 + 播放高亮) ③ AI 纪要。
/// 未处理 → 「生成转写+纪要」调真后端 /process 存本地;已处理 → 直接读本地。
class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  final _player = AudioPlayer();
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  bool _processing = false; // /process 重转写中(无逐字稿路径)
  String? _error;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration?>? _durSub;
  String? _loadedPath;

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _ensureLoaded(Recording rec) async {
    if (_loadedPath == rec.audioPath) return;
    _loadedPath = rec.audioPath;
    try {
      final path = await _playablePath(rec.audioPath);
      await _player.setFilePath(path);
    } catch (e) {
      _loadedPath = null; // 失败允许下次重试
      setState(() => _error = '加载音频失败:$e');
      return;
    }
    _durSub ??= _player.durationStream.listen((d) {
      if (d != null && mounted) setState(() => _dur = d);
    });
    _posSub ??= _player.positionStream.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
  }

  /// 新机 .opus(88B 记录流)→ 重封装成可播 Ogg-Opus(缓存同名 .ogg);旧机 .mp3/.wav 原样直接播(不动)。
  Future<String> _playablePath(String audioPath) async {
    if (!audioPath.toLowerCase().endsWith('.opus')) return audioPath;
    final oggPath = '$audioPath.ogg';
    final cached = File(oggPath);
    if (await cached.exists() && await cached.length() > 0) return oggPath;
    final raw = await File(audioPath).readAsBytes();
    final ogg = OggOpusMuxer.mux(raw);
    if (ogg.isEmpty) throw Exception('opus 数据为空或损坏');
    await cached.writeAsBytes(ogg, flush: true);
    return oggPath;
  }

  Future<void> _generate(Recording rec) async {
    setState(() {
      _processing = true;
      _error = null;
    });
    final store = ref.read(recordingStoreProvider.notifier);
    await store.update(rec.copyWith(status: RecStatus.processing));
    try {
      final bytes = await File(rec.audioPath).readAsBytes();
      final res = await AiClient.process(
        baseUrl: ref.read(backendBaseProvider),
        bytes: bytes,
        filename: '${rec.id}.mp3',
      );
      final finals = res.transcript.where((s) => s.isFinal).toList();
      await store.update(rec.copyWith(
        status: RecStatus.done,
        transcript: finals,
        summary: res.summary,
      ));
    } catch (e) {
      setState(() => _error = '$e');
      await store.update(rec.copyWith(status: RecStatus.error));
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  /// 删除这场会议:确认 → store.remove(删音频文件 + 索引)→ 返回列表。
  Future<void> _confirmDelete(Recording r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('删除这场会议?'),
        content: const Text('音频和记录都会删掉,不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(recordingStoreProvider.notifier).remove(r.id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final recs = ref.watch(recordingStoreProvider);
    Recording? rec;
    for (final r in recs) {
      if (r.id == widget.id) rec = r;
    }
    if (rec == null) {
      return const Scaffold(body: Center(child: Text('录音不存在')));
    }
    final r = rec;
    _ensureLoaded(r);

    final hasResult = r.transcript != null;
    final curIdx = hasResult
        ? currentSegmentIndex(r.transcript!, _pos.inMilliseconds)
        : -1;
    // 纪要生成态来自 app 级 provider(不挂本页 State:离开页也跑完并写回)。
    final gen = ref.watch(summaryGenProvider)[r.id] ?? const SummaryGenState();

    return Scaffold(
      appBar: AppBar(
        title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (hasResult)
            IconButton(
              tooltip: '重新生成纪要',
              icon: const Icon(Icons.refresh),
              onPressed: gen.running ? null : () => ref.read(summaryGenProvider.notifier).generate(r),
            ),
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'delete') _confirmDelete(r);
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'delete',
                child: Row(children: [
                  Icon(Icons.delete_outline, size: 20, color: Colors.red),
                  SizedBox(width: 8),
                  Text('删除', style: TextStyle(color: Colors.red)),
                ]),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _player1(),
          const SizedBox(height: 8),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 8),
              color: const Color(0xFFFDECEA),
              child: Text('错误:$_error', style: const TextStyle(color: Colors.red)),
            ),
          // 1C 留痕:本场目标(有才显示)
          if (r.goal != null && r.goal!.trim().isNotEmpty) ...[
            _h('本场目标'),
            Text(r.goal!.trim()),
            const SizedBox(height: 16),
          ],
          // 2-CTX 留痕:客户背景(有才显示)
          if (r.clientBackground != null && r.clientBackground!.trim().isNotEmpty) ...[
            _h('客户背景'),
            Text(r.clientBackground!.trim()),
            const SizedBox(height: 16),
          ],
          if (!hasResult) _generateBlock(r) else ...[
            _h('转写(${r.transcript!.length} 段)·点段跳转,播放高亮'),
            for (int i = 0; i < r.transcript!.length; i++)
              _segTile(r.transcript![i], highlighted: i == curIdx),
            const SizedBox(height: 16),
            _h('AI 纪要'),
            if (gen.running)
              _summaryStreaming(gen.text)
            else if (r.summaryText != null && r.summaryText!.trim().isNotEmpty)
              _summaryDone(r, r.summaryText!)
            else if (gen.error != null)
              _summaryError(r, gen.error!)
            else if (r.summary != null)
              _summary(r.summary!) // 历史:/process 的结构化纪要
            else
              _summaryButton(r),
          ],
          // 1C 留痕:会中问答(有才显示)
          if (r.askHistory.isNotEmpty) ...[
            const SizedBox(height: 16),
            _h('会中问答(${r.askHistory.length})'),
            for (final qa in r.askHistory) _qaTile(qa),
          ],
          // 1C 留痕:主动提示(有才显示)
          if (r.cueHistory.isNotEmpty) ...[
            const SizedBox(height: 16),
            _h('主动提示(${r.cueHistory.length})'),
            for (final c in r.cueHistory) _cueTile(c),
          ],
        ],
      ),
    );
  }

  Widget _player1() {
    final maxMs = _dur.inMilliseconds <= 0 ? 1 : _dur.inMilliseconds;
    final v = _pos.inMilliseconds.clamp(0, maxMs).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // 极简「波形」装饰(真波形需音频分析,本期从简)
            SizedBox(
              height: 28,
              child: Row(
                children: List.generate(40, (i) {
                  final played = i / 40 <= v / maxMs;
                  return Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      height: 6 + (i * 7 % 20).toDouble(),
                      color: played ? Colors.teal : Colors.teal.withValues(alpha: 0.2),
                    ),
                  );
                }),
              ),
            ),
            Row(
              children: [
                StreamBuilder<PlayerState>(
                  stream: _player.playerStateStream,
                  builder: (context, snap) {
                    final playing = snap.data?.playing ?? false;
                    return IconButton.filled(
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      onPressed: () => playing ? _player.pause() : _player.play(),
                    );
                  },
                ),
                Expanded(
                  child: Slider(
                    value: v,
                    max: maxMs.toDouble(),
                    onChanged: (x) => _player.seek(Duration(milliseconds: x.round())),
                  ),
                ),
              ],
            ),
            Text('${_fmt(_pos)} / ${_fmt(_dur)}', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _generateBlock(Recording r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const Icon(Icons.auto_awesome, size: 40, color: Colors.teal),
          const SizedBox(height: 8),
          const Text('该录音还没转写/纪要', style: TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _processing ? null : () => _generate(r),
            icon: _processing
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_processing ? '生成中…（长录音可能数分钟）' : '生成转写+纪要'),
          ),
        ],
      ),
    );
  }

  Widget _segTile(AiTranscriptSeg s, {required bool highlighted}) {
    final ts = s.startMs != null ? '${(s.startMs! / 1000).toStringAsFixed(1)}s' : '';
    return InkWell(
      onTap: () {
        _player.seek(Duration(milliseconds: s.startMs ?? 0));
        _player.play();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 6),
        margin: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: highlighted ? const Color(0xFFB2DFDB) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(right: 8, top: 1),
              decoration: BoxDecoration(
                color: s.speaker == '说话人1' ? const Color(0xFFE0F2F1) : const Color(0xFFFFF3E0),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(s.speaker.isEmpty ? '?' : s.speaker, style: const TextStyle(fontSize: 11)),
            ),
            if (ts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 6, top: 1),
                child: Text(ts, style: const TextStyle(fontSize: 10, color: Colors.black45)),
              ),
            Expanded(
              child: Text(s.text,
                  style: TextStyle(fontWeight: highlighted ? FontWeight.w600 : FontWeight.normal)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _qaTile(AskEntry qa) => Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFDE7),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('问:${qa.question}', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(qa.answer),
          ],
        ),
      );

  Widget _cueTile(CueEntry c) => Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xFFE3F2FD),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(c.cue),
            if (c.rationale != null && c.rationale!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(c.rationale!, style: const TextStyle(fontSize: 11, color: Colors.black54)),
              ),
          ],
        ),
      );

  Widget _summaryButton(Recording r) => Align(
        alignment: Alignment.centerLeft,
        child: FilledButton.icon(
          onPressed: () => ref.read(summaryGenProvider.notifier).generate(r),
          icon: const Icon(Icons.auto_awesome),
          label: const Text('✨ 生成 AI 纪要'),
          style: FilledButton.styleFrom(backgroundColor: Colors.teal),
        ),
      );

  // 生成中:spinner + 已到的流式文本(逐 token 打印)。
  Widget _summaryStreaming(String text) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Text('AI 纪要生成中…', style: TextStyle(color: Colors.teal.shade700, fontSize: 13)),
          ]),
          if (text.isNotEmpty) ...[
            const SizedBox(height: 8),
            _markdown(text),
          ],
        ],
      );

  // 已生成:渲染 markdown + 重新生成。
  Widget _summaryDone(Recording r, String text) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _markdown(text),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => ref.read(summaryGenProvider.notifier).generate(r),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新生成'),
          ),
        ],
      );

  Widget _summaryError(Recording r, String err) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('纪要生成失败', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600)),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(err,
                style: const TextStyle(fontSize: 12, color: Colors.black45),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => ref.read(summaryGenProvider.notifier).generate(r),
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      );

  /// 轻量 markdown 渲染(## 标题 / - 列表 / 普通段),不引依赖。流式与定稿共用。
  Widget _markdown(String md) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final raw in md.split('\n')) _mdLine(raw)],
      );

  Widget _mdLine(String raw) {
    final t = raw.trimRight();
    if (t.isEmpty) return const SizedBox(height: 6);
    if (t.startsWith('## ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 3),
        child: Text(t.substring(3),
            style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal)),
      );
    }
    if (t.startsWith('# ')) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 3),
        child: Text(t.substring(2), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );
    }
    if (t.startsWith('- ') || t.startsWith('* ')) {
      return Padding(
        padding: const EdgeInsets.only(left: 4, top: 1, bottom: 1),
        child: Text('·  ${t.substring(2)}'),
      );
    }
    return Padding(padding: const EdgeInsets.symmetric(vertical: 1), child: Text(t));
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

  Widget _list(String title, List<String> items) {
    final real = items.where((e) => e != '无').toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sub('$title(${real.length})'),
        if (real.isEmpty)
          const Text('—', style: TextStyle(color: Colors.black54))
        else
          for (final i in real) Text('· $i'),
      ],
    );
  }

  Widget _h(String t) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.teal)),
      );

  Widget _sub(String t) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  static String _fmt(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
}
