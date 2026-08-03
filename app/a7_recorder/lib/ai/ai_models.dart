/// 后端 /process 返回的数据模型。容错解析(字段缺失不崩)。
class AiTranscriptSeg {
  final String speaker;
  final String text;
  final int? startMs;
  final int? endMs;
  final bool isFinal;

  const AiTranscriptSeg({
    required this.speaker,
    required this.text,
    this.startMs,
    this.endMs,
    required this.isFinal,
  });

  factory AiTranscriptSeg.fromJson(Map<String, dynamic> j) => AiTranscriptSeg(
        speaker: (j['speaker'] ?? '') as String,
        text: (j['text'] ?? '') as String,
        startMs: (j['startMs'] as num?)?.toInt(),
        endMs: (j['endMs'] as num?)?.toInt(),
        isFinal: (j['isFinal'] ?? false) as bool,
      );

  Map<String, dynamic> toJson() => {
        'speaker': speaker,
        'text': text,
        'startMs': startMs,
        'endMs': endMs,
        'isFinal': isFinal,
      };
}

class AiSummary {
  final String narrative;
  final List<String> decisions;
  final List<String> actionItems;
  final List<String> openQuestions;
  final List<String> takeaways;

  const AiSummary({
    required this.narrative,
    required this.decisions,
    required this.actionItems,
    required this.openQuestions,
    required this.takeaways,
  });

  static List<String> _strs(dynamic v) =>
      v is List ? v.map((e) => e.toString()).toList() : <String>[];

  factory AiSummary.fromJson(Map<String, dynamic> j) => AiSummary(
        narrative: (j['narrative'] ?? '') as String,
        decisions: _strs(j['decisions']),
        actionItems: _strs(j['actionItems']),
        openQuestions: _strs(j['openQuestions']),
        takeaways: _strs(j['takeaways']),
      );

  Map<String, dynamic> toJson() => {
        'narrative': narrative,
        'decisions': decisions,
        'actionItems': actionItems,
        'openQuestions': openQuestions,
        'takeaways': takeaways,
      };
}

class AiResult {
  final List<AiTranscriptSeg> transcript;
  final AiSummary? summary;
  final String? summaryMarkdown;
  final Map<String, dynamic> raw;
  final Map<String, dynamic> timings;

  const AiResult({
    required this.transcript,
    required this.summary,
    required this.summaryMarkdown,
    required this.raw,
    required this.timings,
  });

  factory AiResult.fromJson(Map<String, dynamic> j) => AiResult(
        transcript: (j['transcript'] as List? ?? const [])
            .map((e) => AiTranscriptSeg.fromJson(e as Map<String, dynamic>))
            .toList(),
        summary: j['summary'] != null
            ? AiSummary.fromJson(j['summary'] as Map<String, dynamic>)
            : null,
        summaryMarkdown: j['summaryMarkdown'] as String?,
        raw: (j['raw'] as Map<String, dynamic>?) ?? const {},
        timings: (j['timings'] as Map<String, dynamic>?) ?? const {},
      );
}
