import '../ai/ai_models.dart';

/// 录音来源:从设备 BLE 下载 / 内置真 A7 样本 / 实时录制 / 本地导入。
enum RecSource { device, sample, live, upload }

/// 处理状态。
enum RecStatus { unprocessed, processing, done, error }

/// 会中问答留痕(一问一答)。
class AskEntry {
  final String question;
  final String answer;
  const AskEntry({required this.question, required this.answer});

  Map<String, dynamic> toJson() => {'question': question, 'answer': answer};

  factory AskEntry.fromJson(Map<String, dynamic> j) => AskEntry(
        question: j['question'] as String? ?? '',
        answer: j['answer'] as String? ?? '',
      );
}

/// 会中主动提示留痕(出现过的提示)。
class CueEntry {
  final String cue;
  final String? rationale;
  const CueEntry({required this.cue, this.rationale});

  Map<String, dynamic> toJson() =>
      {'cue': cue, if (rationale != null) 'rationale': rationale};

  factory CueEntry.fromJson(Map<String, dynamic> j) => CueEntry(
        cue: j['cue'] as String? ?? '',
        rationale: j['rationale'] as String?,
      );
}

/// 一条录音条目(产品骨架的数据单元)。
class Recording {
  final String id;
  final RecSource source;
  final String audioPath; // 本地音频文件路径
  final String title;
  final int durationMs;
  final RecStatus status;
  final List<AiTranscriptSeg>? transcript; // /process 的转写(final 段)
  final AiSummary? summary; // /process 的纪要
  final DateTime createdAt;
  // 1C 留痕:本场目标 / 会中问答 / 主动提示;2-CTX 留痕:客户背景
  final String? goal;
  final String? clientBackground;
  final String? summaryText; // 流式 markdown 纪要(/summarize 写回;不重转写)
  final List<AskEntry> askHistory;
  final List<CueEntry> cueHistory;

  const Recording({
    required this.id,
    required this.source,
    required this.audioPath,
    required this.title,
    required this.durationMs,
    required this.status,
    required this.createdAt,
    this.transcript,
    this.summary,
    this.goal,
    this.clientBackground,
    this.summaryText,
    this.askHistory = const [],
    this.cueHistory = const [],
  });

  Recording copyWith({
    String? title,
    int? durationMs,
    RecStatus? status,
    List<AiTranscriptSeg>? transcript,
    AiSummary? summary,
    String? goal,
    String? clientBackground,
    String? summaryText,
    List<AskEntry>? askHistory,
    List<CueEntry>? cueHistory,
  }) =>
      Recording(
        id: id,
        source: source,
        audioPath: audioPath,
        title: title ?? this.title,
        durationMs: durationMs ?? this.durationMs,
        status: status ?? this.status,
        transcript: transcript ?? this.transcript,
        summary: summary ?? this.summary,
        goal: goal ?? this.goal,
        clientBackground: clientBackground ?? this.clientBackground,
        summaryText: summaryText ?? this.summaryText,
        askHistory: askHistory ?? this.askHistory,
        cueHistory: cueHistory ?? this.cueHistory,
        createdAt: createdAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'source': source.name,
        'audioPath': audioPath,
        'title': title,
        'durationMs': durationMs,
        'status': status.name,
        'transcript': transcript?.map((s) => s.toJson()).toList(),
        'summary': summary?.toJson(),
        'createdAt': createdAt.millisecondsSinceEpoch,
        'goal': goal,
        'clientBackground': clientBackground,
        'summaryText': summaryText,
        'askHistory': askHistory.map((e) => e.toJson()).toList(),
        'cueHistory': cueHistory.map((e) => e.toJson()).toList(),
      };

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: j['id'] as String,
        source: RecSource.values.firstWhere(
          (e) => e.name == j['source'],
          orElse: () => RecSource.sample,
        ),
        audioPath: j['audioPath'] as String,
        title: j['title'] as String,
        durationMs: (j['durationMs'] as num?)?.toInt() ?? 0,
        status: RecStatus.values.firstWhere(
          (e) => e.name == j['status'],
          orElse: () => RecStatus.unprocessed,
        ),
        transcript: (j['transcript'] as List?)
            ?.map((e) => AiTranscriptSeg.fromJson(e as Map<String, dynamic>))
            .toList(),
        summary: j['summary'] != null
            ? AiSummary.fromJson(j['summary'] as Map<String, dynamic>)
            : null,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (j['createdAt'] as num?)?.toInt() ?? 0,
        ),
        // 向后兼容:老数据无这些字段 → goal/clientBackground=null、列表为空,绝不崩。
        goal: j['goal'] as String?,
        clientBackground: j['clientBackground'] as String?,
        summaryText: j['summaryText'] as String?,
        askHistory: (j['askHistory'] as List?)
                ?.map((e) => AskEntry.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
        cueHistory: (j['cueHistory'] as List?)
                ?.map((e) => CueEntry.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}
