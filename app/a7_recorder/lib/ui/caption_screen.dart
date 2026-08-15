import 'dart:async';
import 'dart:convert';

import 'package:a7_protocol/a7_protocol.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';

import '../ai/ai_client.dart';
import '../ai/ai_models.dart';
import '../ai/backend.dart';
import '../ai/caption_client.dart';
import '../ble/fake_unbounded_transport.dart';
import '../device/a7_device.dart';
import '../library/recording.dart';
import '../library/recording_store.dart';
import '../recording/live_recording_state.dart';
import '../recording/recording_audio_sink.dart';
import '../recording/recording_keep_alive.dart';
import 'connection_indicator.dart';
import 'detail_screen.dart';
import 'recording_banner.dart';
import 'theme.dart';

/// 会中屏(会议副驾):音频源(真机 A7 B0B3 / 模拟器回放)→ 后端 /stream → 活字幕;
/// 同时「问 AI(/ask 流式小抄)」「主动提示(/advise 克制)」「留痕(/save)」。
///
/// 表现层做成「安静的会议副驾」:小抄为主角、字幕折叠、底部单一主操作、状态说人话。
/// ⚠️ 本屏只重构表现层,所有功能接线保持不变。
class CaptionScreen extends ConsumerStatefulWidget {
  const CaptionScreen({super.key});

  @override
  ConsumerState<CaptionScreen> createState() => _CaptionScreenState();
}

enum _Src { phone, real, sim }

class _CaptionScreenState extends ConsumerState<CaptionScreen> {
  _Src _src = _Src.phone; // 默认手机收音(零门槛);real=录音卡 A7;sim=模拟器自测(标题长按)
  bool _running = false;
  bool _ready = false; // 收到 /stream ready(开始送音频)→「在听」

  final List<CaptionMsg> _finals = [];
  CaptionMsg? _interim;
  String? _error;
  AiSummary? _summary; // 留痕槽位(本屏不再生成纪要,纪要在详情页生成)

  CaptionClient? _client;
  StreamSubscription<CaptionMsg>? _capSub;
  StreamSubscription<List<int>>? _audioSub;
  FakeUnboundedTransport? _fake;
  AudioRecorder? _mic; // 手机收音(record):PCM 流
  List<int>? _rtBytes;
  final RecordingAudioSink _audioSink = RecordingAudioSink();
  final _scrollCtl = ScrollController();

  // 录音计时(顶部「在听」时长)
  Timer? _tick;
  int _elapsedSec = 0;

  // 会前准备:本场目标(_goalCtl 持有)+ 客户背景(会前情报,过往了解)
  String _clientBackground = '';
  // 会中问 AI(被动·流式)
  final _goalCtl = TextEditingController();
  final _askCtl = TextEditingController();
  String _cue = ''; // 流式累积的「小抄」
  bool _asking = false;
  String? _askErr;
  StreamSubscription<String>? _askSub;

  // 会中主动提示(被动·克制)
  Timer? _adviseTimer;
  bool _advising = false; // 在飞守卫
  String? _activeCue; // 当前展示的主动提示(null=无)
  String? _activeRationale;
  String _lastCue = ''; // 去重:上次展示过的 cue
  String? _adviseErr;

  // 1C 留痕:本场会话累积的问答 / 主动提示
  final List<AskEntry> _askHistory = [];
  final List<CueEntry> _cueHistory = [];

  @override
  void dispose() {
    unawaited(RecordingKeepAlive.stop());
    ref.read(liveRecordingProvider.notifier).onStop();
    _capSub?.cancel();
    _audioSub?.cancel();
    _askSub?.cancel();
    _adviseTimer?.cancel();
    _tick?.cancel();
    _fake?.dispose();
    _mic?.dispose();
    _client?.close();
    unawaited(_audioSink.close());
    _scrollCtl.dispose();
    _goalCtl.dispose();
    _askCtl.dispose();
    super.dispose();
  }

  String _sourceLabel() => switch (_src) {
        _Src.phone => '手机麦克风',
        _Src.real => 'A7 录音卡',
        _Src.sim => '模拟器回放',
      };

  // ───────────────────────── 逻辑(接线全保留,未改语义) ─────────────────────────

  /// 周期触发主动提示:录音中、每 ~25s 调一次 /advise(_runAdvise 内部再守在飞/逐字稿空)。
  void _startAdviseLoop() {
    _adviseTimer?.cancel();
    _adviseTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_running) _runAdvise();
    });
  }

  /// 调 /advise:在飞守卫 + 逐字稿空则安静;shouldPrompt 且非重复才弹主动提示卡。
  Future<void> _runAdvise() async {
    if (_advising) return; // 在飞守卫:同时只一条
    final transcript = _finals.map((m) => '${m.speaker}: ${m.text}').join('\n');
    if (transcript.trim().isEmpty) return; // 逐字稿空 → 安静
    setState(() {
      _advising = true;
      _adviseErr = null;
    });
    try {
      final c = await AiClient.advise(
        baseUrl: ref.read(backendBaseProvider),
        goal: _goalCtl.text.trim().isEmpty ? null : _goalCtl.text.trim(),
        clientBackground: _clientBackground.trim().isEmpty ? null : _clientBackground.trim(),
        transcript: transcript,
      );
      if (!mounted) return;
      // 克制:仅 shouldPrompt 且与上次不相似才弹;否则保持安静、不动现有卡。
      if (c.shouldPrompt && c.cue.trim().isNotEmpty && !_similarCue(c.cue, _lastCue)) {
        final rationale = c.rationale.trim().isEmpty ? null : c.rationale.trim();
        _cueHistory.add(CueEntry(cue: c.cue.trim(), rationale: rationale)); // 留痕
        setState(() {
          _activeCue = c.cue.trim();
          _activeRationale = rationale;
          _lastCue = c.cue.trim();
        });
      }
    } catch (e) {
      if (mounted) setState(() => _adviseErr = '$e');
    } finally {
      if (mounted) setState(() => _advising = false);
    }
  }

  /// 防烦去重:完全相同 或 一方包含另一方,视为近似,不重复弹。
  bool _similarCue(String a, String b) {
    if (b.isEmpty) return false;
    final x = a.trim();
    final y = b.trim();
    return x == y || x.contains(y) || y.contains(x);
  }

  /// 会中问 AI:把已定稿逐字稿 + 本场目标 + 问题 发 /ask,逐 token 流式累积成小抄。
  Future<void> _ask() async {
    final q = _askCtl.text.trim();
    if (q.isEmpty) return;
    await _askSub?.cancel();
    setState(() {
      _asking = true;
      _askErr = null;
      _cue = '';
    });
    final transcript = _finals.map((m) => '${m.speaker}: ${m.text}').join('\n');
    final goal = _goalCtl.text.trim();
    _askSub = AiClient.ask(
      baseUrl: ref.read(backendBaseProvider),
      goal: goal.isEmpty ? null : goal,
      clientBackground: _clientBackground.trim().isEmpty ? null : _clientBackground.trim(),
      transcript: transcript,
      question: q,
    ).listen(
      (tok) {
        if (mounted) {
          setState(() => _cue += tok);
        }
      },
      onError: (Object e) {
        if (mounted) {
          setState(() {
            _askErr = '$e';
            _asking = false;
          });
        }
      },
      onDone: () {
        // 完成时归档这轮问答(_cue 下次问会被清空覆盖,必须此刻存)
        if (_cue.trim().isNotEmpty) {
          _askHistory.add(AskEntry(question: q, answer: _cue.trim()));
        }
        if (mounted) {
          setState(() => _asking = false);
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> _start() async {
    await _audioSink.close();
    await _audioSink.deleteTemp();
    setState(() {
      _running = true;
      _ready = false;
      _error = null;
      _finals.clear();
      _interim = null;
      _summary = null;
      _activeCue = null;
      _activeRationale = null;
      _lastCue = '';
      _adviseErr = null;
      _askHistory.clear();
      _cueHistory.clear();
      _elapsedSec = 0;
    });
    ref.read(liveRecordingProvider.notifier).onStart(sourceLabel: _sourceLabel());
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_running && mounted) {
        setState(() => _elapsedSec++);
        ref.read(liveRecordingProvider.notifier).onTick(_elapsedSec);
        unawaited(RecordingKeepAlive.updateNotification(
          text: '录音中 ${RecordingBanner.fmtClock(_elapsedSec)} · 点击返回 App',
        ));
      }
    });
    try {
      await RecordingKeepAlive.start();
      // WS 分流:手机→?fmt=pcm;A7 新机→?fmt=opus;A7 旧机/模拟器→无参(mp3,走 ffmpeg 老路)。
      final base = wsStreamUrl(ref.read(backendBaseProvider));
      final String wsUrl = _src == _Src.phone
          ? '$base?fmt=pcm'
          : (_src == _Src.real && _realCodec() == 'opus' ? '$base?fmt=opus' : base);
      final c = CaptionClient.connect(wsUrl);
      _client = c;
      _startAdviseLoop(); // 录音中周期主动提示
      _capSub = c.messages.listen(
        _onMsg,
        onError: (Object e) {
          // 后台网络闪断时不自动停录音;用户可手动结束并保存。
          if (mounted) setState(() => _error = '字幕连接中断:$e(本地收音可能仍在继续)');
        },
        onDone: () {
          if (_running && mounted) {
            setState(() => _error ??= '字幕连接已断开(本地收音可能仍在继续)');
          }
        },
      );
    } catch (e) {
      await RecordingKeepAlive.stop();
      setState(() {
        _error = '$e';
        _running = false;
      });
      _tick?.cancel();
    }
  }

  void _onMsg(CaptionMsg m) {
    switch (m.type) {
      case 'ready':
        setState(() => _ready = true);
        ref.read(liveRecordingProvider.notifier).onReady();
        _startAudio();
        break;
      case 'transcript':
        setState(() {
          if (m.isFinal) {
            _finals.add(m);
            _interim = null;
          } else {
            _interim = m; // interim 仅预览,可被下一条覆盖
          }
        });
        _autoScroll();
        break;
      case 'error':
        setState(() => _error = m.error);
        _stop();
        break;
      case 'done':
        setState(() => _running = false);
        _tick?.cancel();
        _stopAudioOnly();
        break;
    }
  }

  Future<void> _startAudio() async {
    try {
      final isPhone = _src == _Src.phone;
      await _audioSink.open(pcm: isPhone);
      if (_src == _Src.phone) {
        // 手机麦克风:PCM s16le / 16k / mono(RTASR 帧就吃这个);先要权限。
        final mic = AudioRecorder();
        _mic = mic;
        if (!await mic.hasPermission()) {
          setState(() => _error = '音频源:没有麦克风权限,请在系统设置里允许后重试');
          return;
        }
        final stream = await mic.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          // 来电等中断后尽量自动恢复收音(iOS 需 Info.plist audio 后台模式)。
          audioInterruption: AudioInterruptionMode.pauseResume,
        ));
        _audioSub = stream.cast<List<int>>().listen((b) {
          _client?.sendAudio(b);
          _audioSink.write(b);
        });
      } else if (_src == _Src.sim) {
        _rtBytes ??= (await rootBundle.load('assets/live_b3.mp3')).buffer.asUint8List();
        final t = FakeUnboundedTransport(realtimeBytes: _rtBytes!);
        _fake = t;
        _audioSub = t.realtime.listen((b) {
          _client?.sendAudio(b);
          _audioSink.write(b);
        });
        await t.connect('caption-demo'); // 无界循环推 live_b3.mp3
      } else {
        final t = ref.read(transportProvider);
        await t.writeCommand(startRecording(_recName(), 1)); // 0x06 开录
        _audioSub = t.realtime.listen((b) {
          _client?.sendAudio(b);
          _audioSink.write(b);
        });
      }
    } catch (e) {
      setState(() => _error = '音频源:$e');
    }
  }

  Future<void> _stop() async {
    _adviseTimer?.cancel();
    _tick?.cancel();
    _client?.end();
    await _stopAudioOnly();
    await _audioSink.close();
    await RecordingKeepAlive.stop();
    ref.read(liveRecordingProvider.notifier).onStop();
    if (mounted) setState(() => _running = false);
  }

  Future<void> _stopAudioOnly() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _fake?.dispose();
    _fake = null;
    if (_mic != null) {
      try {
        await _mic!.stop();
      } catch (_) {}
      await _mic!.dispose();
      _mic = null;
    }
    if (_src == _Src.real) {
      try {
        await ref.read(transportProvider).writeCommand(stopRecording()); // 0x07
      } catch (_) {}
    }
  }

  /// 结束并保存:停流 → 落库(带 1C 留痕)→ 进该会议详情。
  Future<void> _endAndSave() async {
    if (_running) await _stop();
    final id = await _save();
    if (!mounted) return;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这场还没录到音频')),
      );
      return;
    }
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => DetailScreen(id: id)),
    );
  }

  /// 把这段实时录音(音频 + 实时转写 final 段 + 1C 留痕)存为录音库一条;返回新条目 id。
  Future<String?> _save() async {
    if (!_audioSink.hasData) return null;
    final store = ref.read(recordingStoreProvider.notifier);
    final id = 'live-${DateTime.now().millisecondsSinceEpoch}';
    final bool isPhone = _src == _Src.phone;
    final bool isOpus = _src == _Src.real && _realCodec() == 'opus';
    final String ext = isPhone ? 'wav' : (isOpus ? 'opus' : 'mp3');
    final bytesWritten = _audioSink.bytesWritten;

    late final String path;
    if (isPhone) {
      final out = await store.audioPathFor(id, ext: ext);
      await _audioSink.writeWavFromPcmFile(out);
      path = out;
    } else {
      final out = await store.audioPathFor(id, ext: ext);
      await _audioSink.copyRawTo(out);
      path = out;
    }
    await _audioSink.deleteTemp();

    final segs = _finals
        .map((m) => AiTranscriptSeg(
              speaker: m.speaker,
              text: m.text,
              startMs: m.startMs,
              endMs: m.endMs,
              isFinal: true,
            ))
        .toList();
    final rec = Recording(
      id: id,
      source: RecSource.live,
      audioPath: path,
      title: '实时录音 ${_recName()}',
      durationMs: isPhone
          ? (bytesWritten ~/ 32)
          : isOpus
              ? (bytesWritten ~/ 88) * 20
              : mp3DurationMsFromBytes(bytesWritten),
      status: segs.isEmpty ? RecStatus.unprocessed : RecStatus.done,
      transcript: segs.isEmpty ? null : segs,
      createdAt: DateTime.now(),
      goal: _goalCtl.text.trim().isEmpty ? null : _goalCtl.text.trim(),
      clientBackground: _clientBackground.trim().isEmpty ? null : _clientBackground.trim(),
      summary: _summary,
      askHistory: List.of(_askHistory),
      cueHistory: List.of(_cueHistory),
    );
    await store.add(rec);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已存入录音库(${segs.length} 段转写)')),
      );
    }
    return id;
  }

  String _recName() {
    final n = DateTime.now();
    String t2(int x) => x.toString().padLeft(2, '0');
    return '${t2(n.year % 100)}${t2(n.month)}${t2(n.day)}${t2(n.hour)}${t2(n.minute)}${t2(n.second)}';
  }

  /// 当前连接 A7 的音频编码('opus' 新机 X95-AINOTE / 'mp3' 旧机),按 model/SN 判定(唯一判据)。
  String _realCodec() {
    final s = ref.read(a7Provider);
    return audioCodecOf(model: s.info?.model, sn: s.device?.sn);
  }

  /// 裸 PCM(s16le/16k/mono)→ 可播放 WAV(44 字节 RIFF 头 + 数据)。just_audio 能放。
  // _wavFromPcm 已迁移至 RecordingAudioSink，录音期间流式落盘。

  void _autoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtl.hasClients) {
        _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent);
      }
    });
  }

  /// 标题长按:模拟器自测开关(隐藏入口,录音中禁切)。开 → sim;关 → 回手机。
  void _toggleSrc() {
    if (_running) return;
    setState(() => _src = _src == _Src.sim ? _Src.phone : _Src.sim);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('音频源:${_src == _Src.sim ? '模拟器回放(自测)' : '手机麦克风'}')),
    );
  }

  /// 点「会前准备」→ 进会前准备表单(PrepForm 自持控制器、自身 dispose;不再由本屏 new/dispose
  /// 控制器,根除旧弹框「dispose 时对话框还没卸载」的 '_dependents.isEmpty' 崩溃)。
  Future<void> _openPrep() async {
    final res = await Navigator.of(context).push<PrepResult>(
      MaterialPageRoute(
        builder: (_) => PrepForm(goal: _goalCtl.text, clientBackground: _clientBackground),
      ),
    );
    if (res != null && mounted) {
      setState(() {
        _goalCtl.text = res.goal;
        _clientBackground = res.clientBackground;
      });
    }
  }

  /// 把内部报错映射成人话(原始报错另以小字附在下面供排查)。
  String _friendlyError(String raw) {
    final r = raw.toLowerCase();
    if (raw.startsWith('WS') ||
        r.contains('websocket') ||
        r.contains('socketexception') ||
        r.contains('connection')) {
      return '网络好像断了,请检查网络后重试';
    }
    if (r.contains('麦克风') || r.contains('permission') || r.contains('权限')) {
      return '麦克风权限被拒,请在系统设置里允许后重试';
    }
    if (raw.startsWith('音频源') || r.contains('a7') || r.contains('transport') || r.contains('bluetooth')) {
      return '没连上录音设备,请检查 A7 是否已连接';
    }
    return '出了点问题,请重试';
  }

  // ───────────────────────────── 表现层 ─────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_running,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_running) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('录音进行中，请先点「结束并保存」')),
        );
      },
      child: Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: GestureDetector(
          onLongPress: _toggleSrc, // 自测入口:长按标题切音频源
          child: Text(_running ? '会议中' : '会议'),
        ),
        actions: [const ConnectionIndicator(compact: true), _statusPill()],
      ),
      body: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.s, AppSpacing.m, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_running) ...[
                const RecordingBanner(),
                const SizedBox(height: AppSpacing.s),
              ],
              if (!_running) ...[
                _sourceSelector(),
                const SizedBox(height: AppSpacing.s),
              ],
              _goalBar(),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.s),
                _errorCard(),
              ],
              const SizedBox(height: AppSpacing.m),
              // 主角:小抄大卡(问 AI 的流式小抄)
              Expanded(child: _cueCard()),
              // 主动提示(克制:有才出现、可忽略)
              if (_activeCue != null) ...[
                const SizedBox(height: AppSpacing.s),
                _activeCueBanner(),
              ],
              if (_adviseErr != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.xs),
                  child: Text('主动提示暂时不可用',
                      style: AppText.caption.copyWith(color: AppColors.cueAccent)),
                ),
              const SizedBox(height: AppSpacing.s),
              _askRow(),
              const SizedBox(height: AppSpacing.s),
              _captionsExpansion(),
              const SizedBox(height: AppSpacing.s),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _bottomBar(),
    ),
    );
  }

  /// 顶部状态:连接中 → 转圈「正在连接…」;在听 → 呼吸点 + 计时。
  Widget _statusPill() {
    if (!_running) return const SizedBox.shrink();
    if (!_ready) {
      return Padding(
        padding: const EdgeInsets.only(right: AppSpacing.l),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 6),
            Text('正在连接…', style: AppText.caption),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.l),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _BreathingDot(color: AppColors.danger),
          const SizedBox(width: 6),
          Text(
            _fmtClock(_elapsedSec),
            style: AppText.caption.copyWith(
              color: AppColors.ink,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// 收音方式:手机(默认·零门槛)/ 录音卡(A7·远场更好)。录音中隐藏(不可中途切)。
  Widget _sourceSelector() {
    final sel = _src == _Src.sim ? _Src.phone : _src; // sim 自测态视觉上落在「手机」
    return SegmentedButton<_Src>(
      segments: const [
        ButtonSegment(value: _Src.phone, label: Text('手机'), icon: Icon(Icons.smartphone, size: 16)),
        ButtonSegment(value: _Src.real, label: Text('录音卡'), icon: Icon(Icons.mic_external_on, size: 16)),
      ],
      selected: {sel},
      showSelectedIcon: false,
      onSelectionChanged: (s) => setState(() => _src = s.first),
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
    );
  }

  /// 会前准备入口:🎯 本场目标 +（已填则）📄 客户背景标记(点开进会前准备表单;都未填时引导)。
  Widget _goalBar() {
    final g = _goalCtl.text.trim();
    final hasGoal = g.isNotEmpty;
    final hasBg = _clientBackground.trim().isNotEmpty;
    return Material(
      color: AppColors.tealSoft,
      borderRadius: BorderRadius.circular(AppRadius.field),
      child: InkWell(
        onTap: _openPrep,
        borderRadius: BorderRadius.circular(AppRadius.field),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.m, vertical: 10),
          child: Row(
            children: [
              const Icon(Icons.track_changes, size: 18, color: AppColors.teal),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: Text(
                  hasGoal ? g : '点这里做会前准备:目标 + 客户背景',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: hasGoal
                      ? AppText.body.copyWith(fontWeight: FontWeight.w600, color: AppColors.teal)
                      : AppText.faint.copyWith(color: AppColors.teal.withValues(alpha: 0.75)),
                ),
              ),
              if (hasBg) ...[
                const SizedBox(width: AppSpacing.s),
                const Icon(Icons.description_outlined, size: 15, color: AppColors.teal),
                const SizedBox(width: 2),
                Text('背景',
                    style: AppText.caption.copyWith(color: AppColors.teal, fontWeight: FontWeight.w600)),
              ],
              const SizedBox(width: AppSpacing.s),
              Icon(hasGoal || hasBg ? Icons.edit_outlined : Icons.add, size: 16, color: AppColors.teal),
            ],
          ),
        ),
      ),
    );
  }

  /// 错误卡:友好话 + 关闭;原始报错以小字附下,供排查不糊脸。
  Widget _errorCard() {
    final raw = _error!;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.m),
      decoration: AppTheme.cardDecoration(
          color: AppColors.dangerBg, border: AppColors.danger.withValues(alpha: 0.3)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline, size: 18, color: AppColors.danger),
              const SizedBox(width: AppSpacing.s),
              Expanded(
                child: Text(_friendlyError(raw),
                    style: AppText.body.copyWith(color: AppColors.danger, fontWeight: FontWeight.w600)),
              ),
              GestureDetector(
                onTap: () => setState(() => _error = null),
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.close, size: 16, color: AppColors.danger),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(raw,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: AppColors.inkFaint)),
        ],
      ),
    );
  }

  /// 主角:小抄大卡(流式逐字)+「立即提示」。
  Widget _cueCard() {
    final empty = _cue.isEmpty;
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.l, AppSpacing.m, AppSpacing.s, AppSpacing.l),
      decoration: AppTheme.cardDecoration(
        color: AppColors.cueBg,
        border: AppColors.cueAccent.withValues(alpha: 0.25),
        elevated: true,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.tips_and_updates, size: 20, color: AppColors.cueAccent),
              const SizedBox(width: AppSpacing.s),
              const Text('小抄 · 副驾',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.ink)),
              const Spacer(),
              if (_asking)
                const Padding(
                  padding: EdgeInsets.only(right: AppSpacing.s),
                  child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                ),
              // 立即提示:不等定时器,手动强制一次 /advise
              TextButton.icon(
                onPressed: _running && !_advising ? _runAdvise : null,
                icon: _advising
                    ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.bolt, size: 18),
                label: const Text('立即提示'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.cueAccent,
                  padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s),
                  minimumSize: const Size(0, 32),
                  textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s),
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                empty
                    ? (_asking
                        ? '思考中…'
                        : '在下面问一句,小抄会逐字冒出来。\n例:「现在该追问什么把预算问清楚?」「对方刚说的交付时间是哪个?」')
                    : _cue,
                style: empty ? AppText.bodyLarge.copyWith(color: AppColors.inkFaint) : AppText.bodyLarge,
              ),
            ),
          ),
          if (_askErr != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s),
              child: Text('问 AI 出错了,请重试', style: AppText.caption.copyWith(color: AppColors.danger)),
            ),
        ],
      ),
    );
  }

  /// 主动提示卡(蓝,区别于黄色小抄):该问这个 + 理由,可一键忽略。
  Widget _activeCueBanner() {
    return Container(
      padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.s, AppSpacing.s, AppSpacing.s),
      decoration: AppTheme.cardDecoration(
          color: AppColors.adviseBg, border: AppColors.adviseAccent.withValues(alpha: 0.3)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.notifications_active, size: 18, color: AppColors.adviseAccent),
          const SizedBox(width: AppSpacing.s),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('该问这个',
                    style: AppText.caption
                        .copyWith(color: AppColors.adviseAccent, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(_activeCue!, style: AppText.body),
                if (_activeRationale != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(_activeRationale!, style: AppText.caption),
                  ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _activeCue = null),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, size: 18, color: AppColors.inkFaint),
            ),
          ),
        ],
      ),
    );
  }

  /// 问 AI 输入行。
  Widget _askRow() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _askCtl,
            decoration: const InputDecoration(
              hintText: '问 AI:下一句该问什么?',
              prefixIcon: Icon(Icons.auto_awesome, size: 18, color: AppColors.teal),
            ),
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _ask(),
          ),
        ),
        const SizedBox(width: AppSpacing.s),
        SizedBox(
          height: 48,
          width: 52,
          child: FilledButton(
            onPressed: _asking ? null : _ask,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.teal,
              padding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
            ),
            child: _asking
                ? const SizedBox(
                    width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded, size: 20),
          ),
        ),
      ],
    );
  }

  /// 实时字幕:默认折叠,点开看(降为次要区)。
  Widget _captionsExpansion() {
    final n = _finals.length + (_interim != null ? 1 : 0);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: AppTheme.cardDecoration(),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: AppSpacing.m),
          shape: const Border(),
          collapsedShape: const Border(),
          leading: const Icon(Icons.subtitles_outlined, size: 20, color: AppColors.inkSoft),
          title: Text('实时字幕(点开看)${n > 0 ? '  ·  $n 句' : ''}', style: AppText.section),
          childrenPadding: const EdgeInsets.fromLTRB(AppSpacing.m, 0, AppSpacing.m, AppSpacing.m),
          children: [SizedBox(height: 190, child: _captions())],
        ),
      ),
    );
  }

  Widget _captions() {
    final items = <Widget>[
      for (final f in _finals) _line(f, faint: false),
      if (_interim != null) _line(_interim!, faint: true),
    ];
    if (items.isEmpty) {
      return Center(
        child: Text(
          _running ? '字幕会从这里实时滚出来…' : '开始后,实时字幕在这里滚动',
          textAlign: TextAlign.center,
          style: AppText.faint,
        ),
      );
    }
    return ListView(controller: _scrollCtl, padding: EdgeInsets.zero, children: items);
  }

  Widget _line(CaptionMsg m, {required bool faint}) {
    final ts = m.startMs != null ? '${(m.startMs! / 1000).toStringAsFixed(1)}s ' : '';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            margin: const EdgeInsets.only(right: AppSpacing.s, top: 1),
            decoration: BoxDecoration(
              color: m.speaker == '说话人1' ? AppColors.tealSoft : const Color(0xFFFBEEDD),
              borderRadius: BorderRadius.circular(AppRadius.chip),
            ),
            child: Text(m.speaker.isEmpty ? '?' : m.speaker, style: AppText.caption),
          ),
          Expanded(
            child: Text(
              '$ts${m.text}${faint ? ' …' : ''}',
              style: faint
                  ? AppText.body.copyWith(color: AppColors.inkFaint, fontStyle: FontStyle.italic)
                  : AppText.body,
            ),
          ),
        ],
      ),
    );
  }

  /// 底部唯一主操作:录音中=结束并保存;停后有音频=保存并查看;空闲=开始会议。
  Widget _bottomBar() {
    final stoppedWithAudio = !_running && _audioSink.hasData;
    final String label;
    final IconData icon;
    final Color color;
    final VoidCallback onTap;
    if (_running) {
      label = '结束并保存';
      icon = Icons.stop_rounded;
      color = AppColors.danger;
      onTap = _endAndSave;
    } else if (stoppedWithAudio) {
      label = '保存并查看';
      icon = Icons.check_rounded;
      color = AppColors.teal;
      onTap = _endAndSave;
    } else {
      label = '开始会议';
      icon = Icons.mic_rounded;
      color = AppColors.teal;
      onTap = _start;
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.m, AppSpacing.s, AppSpacing.m, AppSpacing.m),
        child: SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: onTap,
            icon: Icon(icon, size: 22),
            label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            style: FilledButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
            ),
          ),
        ),
      ),
    );
  }

  static String _fmtClock(int sec) =>
      '${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')}';
}

/// 「在听」轻呼吸点(透明度 0.35↔1 缓动循环)。
class _BreathingDot extends StatefulWidget {
  const _BreathingDot({required this.color});
  final Color color;

  @override
  State<_BreathingDot> createState() => _BreathingDotState();
}

class _BreathingDotState extends State<_BreathingDot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(
        CurvedAnimation(parent: _c, curve: Curves.easeInOut),
      ),
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(color: widget.color, shape: BoxShape.circle),
      ),
    );
  }
}

/// 会前准备表单返回值:目标 + 客户背景。
class PrepResult {
  const PrepResult(this.goal, this.clientBackground);
  final String goal;
  final String clientBackground;
}

/// 会前准备(独立页):客户背景(打字 / 上传 md|markdown|txt)+ 会议目标。
/// 自持两个控制器、在自身 dispose() 释放 —— 不让调用方 new/dispose 控制器,
/// 从根上避开「弹框还没卸载就 dispose 控制器」的 '_dependents.isEmpty' 崩溃。
class PrepForm extends StatefulWidget {
  const PrepForm({super.key, required this.goal, required this.clientBackground});
  final String goal;
  final String clientBackground;

  @override
  State<PrepForm> createState() => _PrepFormState();
}

class _PrepFormState extends State<PrepForm> {
  late final TextEditingController _goalCtl = TextEditingController(text: widget.goal);
  late final TextEditingController _bgCtl = TextEditingController(text: widget.clientBackground);
  String? _uploadNote;

  @override
  void dispose() {
    _goalCtl.dispose();
    _bgCtl.dispose();
    super.dispose();
  }

  /// 上传背景:只收 .md/.markdown/.txt 文本 → 读成字符串填进背景框(用户可再编辑)。
  Future<void> _uploadBackground() async {
    try {
      final group = XTypeGroup(label: '文本 / Markdown', extensions: const ['md', 'markdown', 'txt']);
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return; // 取消
      final name = file.name.toLowerCase();
      final isText = name.endsWith('.md') || name.endsWith('.markdown') || name.endsWith('.txt');
      if (!isText) {
        setState(() => _uploadNote = '只支持 .md / .markdown / .txt 文本文件');
        return;
      }
      final bytes = await file.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      setState(() {
        _bgCtl.text = text;
        _uploadNote = '已读入「${file.name}」,可继续编辑';
      });
    } catch (e) {
      setState(() => _uploadNote = '读取失败:$e');
    }
  }

  void _save() => Navigator.of(context).pop(PrepResult(_goalCtl.text.trim(), _bgCtl.text.trim()));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('会前准备'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.l),
        children: [
          _label('客户背景', '这是谁 / 我们什么关系 / 这次想拿什么 / 对方可能的顾虑'),
          const SizedBox(height: AppSpacing.s),
          TextField(
            controller: _bgCtl,
            minLines: 6,
            maxLines: 12,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: '例:老客户,复购为主;认价格、惯压账期;这次想升级到年框;最怕交付延期。',
            ),
          ),
          const SizedBox(height: AppSpacing.s),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _uploadBackground,
                icon: const Icon(Icons.upload_file, size: 18),
                label: const Text('上传 Markdown / 文本'),
              ),
              if (_uploadNote != null) ...[
                const SizedBox(width: AppSpacing.s),
                Expanded(
                  child: Text(_uploadNote!,
                      style: AppText.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          _label('会议目标', '这场要拿到什么'),
          const SizedBox(height: AppSpacing.s),
          TextField(
            controller: _goalCtl,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(hintText: '例:敲定预算上限与交付时间'),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: 50,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.check_rounded),
              label: const Text('保存', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.teal,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.field)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String title, String hint) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.section),
          const SizedBox(height: 2),
          Text(hint, style: AppText.faint),
        ],
      );
}
