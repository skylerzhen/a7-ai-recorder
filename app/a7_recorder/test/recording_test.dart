import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/ai/ai_models.dart';
import 'package:a7_recorder/library/recording.dart';
import 'package:a7_recorder/library/segment_match.dart';

void main() {
  group('currentSegmentIndex(最大 startMs<=pos 的段)', () {
    const segs = [
      AiTranscriptSeg(speaker: '说话人1', text: 'a', startMs: 0, endMs: 1000, isFinal: true),
      AiTranscriptSeg(speaker: '说话人2', text: 'b', startMs: 1000, endMs: 2500, isFinal: true),
      AiTranscriptSeg(speaker: '说话人1', text: 'c', startMs: 2500, endMs: 4000, isFinal: true),
    ];
    test('段内', () => expect(currentSegmentIndex(segs, 1500), 1));
    test('边界取起始于此的段', () => expect(currentSegmentIndex(segs, 2500), 2));
    test('首段之前 → -1', () => expect(currentSegmentIndex(segs, -5), -1));
    test('末段之后 → 末段', () => expect(currentSegmentIndex(segs, 99999), 2));
    test('空 → -1', () => expect(currentSegmentIndex(const [], 100), -1));
  });

  test('Recording JSON 往返相等(含 transcript+summary)', () {
    final r = Recording(
      id: 'r1',
      source: RecSource.sample,
      audioPath: '/tmp/a.mp3',
      title: '测试录音',
      durationMs: 14000,
      status: RecStatus.done,
      transcript: const [
        AiTranscriptSeg(speaker: '说话人1', text: '你好', startMs: 0, endMs: 500, isFinal: true),
      ],
      summary: const AiSummary(
        narrative: 'n',
        decisions: ['d'],
        actionItems: [],
        openQuestions: [],
        takeaways: ['t'],
      ),
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000000000),
    );

    final r2 = Recording.fromJson(r.toJson());
    expect(r2.id, 'r1');
    expect(r2.source, RecSource.sample);
    expect(r2.title, '测试录音');
    expect(r2.durationMs, 14000);
    expect(r2.status, RecStatus.done);
    expect(r2.transcript!.first.text, '你好');
    expect(r2.transcript!.first.startMs, 0);
    expect(r2.summary!.decisions, ['d']);
    expect(r2.summary!.takeaways, ['t']);
    expect(r2.createdAt.millisecondsSinceEpoch, 1700000000000);
  });

  test('未处理 Recording:transcript/summary 为空', () {
    final r = Recording(
      id: 'r2',
      source: RecSource.device,
      audioPath: '/tmp/b.mp3',
      title: 'b',
      durationMs: 0,
      status: RecStatus.unprocessed,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final r2 = Recording.fromJson(r.toJson());
    expect(r2.transcript, isNull);
    expect(r2.summary, isNull);
    expect(r2.status, RecStatus.unprocessed);
  });

  // ── 1C 留痕:向后兼容 + 新字段 round-trip ──
  test('向后兼容:老 JSON(无 goal/askHistory/cueHistory)→ 不崩,新字段为空', () {
    final r = Recording.fromJson(<String, dynamic>{
      'id': 'old1',
      'source': 'live',
      'audioPath': '/x/old1.mp3',
      'title': '老录音',
      'durationMs': 12000,
      'status': 'done',
      'createdAt': 1700000000000,
      // 故意没有 goal / askHistory / cueHistory
    });
    expect(r.id, 'old1');
    expect(r.goal, isNull);
    expect(r.askHistory, isEmpty);
    expect(r.cueHistory, isEmpty);
  });

  test('1C round-trip:goal/问答/提示 toJson→fromJson 保真', () {
    final rec = Recording(
      id: 'rec1c',
      source: RecSource.live,
      audioPath: '/x/rec1c.mp3',
      title: '新录音',
      durationMs: 30000,
      status: RecStatus.done,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000001000),
      goal: '锁定预算',
      askHistory: const [AskEntry(question: '该追问啥?', answer: '问封顶预算')],
      cueHistory: const [CueEntry(cue: '确认十万是上限吗?', rationale: '预算未锁')],
    );
    final back = Recording.fromJson(rec.toJson());
    expect(back.goal, '锁定预算');
    expect(back.askHistory.single.question, '该追问啥?');
    expect(back.askHistory.single.answer, '问封顶预算');
    expect(back.cueHistory.single.cue, '确认十万是上限吗?');
    expect(back.cueHistory.single.rationale, '预算未锁');
  });

  // ── 2-CTX 客户背景:向后兼容 + round-trip ──
  test('2-CTX 向后兼容:老 JSON 无 clientBackground → null,不崩', () {
    final r = Recording.fromJson(<String, dynamic>{
      'id': 'old2',
      'source': 'live',
      'audioPath': '/x/old2.mp3',
      'title': '老录音',
      'durationMs': 1000,
      'status': 'done',
      'createdAt': 1700000000000,
      // 故意没有 clientBackground(也没有 1C 字段)
    });
    expect(r.clientBackground, isNull);
    expect(r.goal, isNull);
    expect(r.askHistory, isEmpty);
  });

  test('2-CTX round-trip:clientBackground toJson→fromJson 保真', () {
    final rec = Recording(
      id: 'recctx',
      source: RecSource.live,
      audioPath: '/x/recctx.mp3',
      title: '带客户背景',
      durationMs: 1000,
      status: RecStatus.done,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000002000),
      clientBackground: '这客户惯压账期、只认价格,采购老王说了算。',
      goal: '签年框',
    );
    final back = Recording.fromJson(rec.toJson());
    expect(back.clientBackground, '这客户惯压账期、只认价格,采购老王说了算。');
    expect(back.goal, '签年框');
  });

  // ── summaryText(流式 markdown 纪要):向后兼容 + round-trip ──
  test('summaryText 向后兼容:老 JSON 无 summaryText → null,不崩', () {
    final r = Recording.fromJson(<String, dynamic>{
      'id': 'old3',
      'source': 'live',
      'audioPath': '/x/old3.mp3',
      'title': '老录音',
      'durationMs': 1000,
      'status': 'done',
      'createdAt': 1700000000000,
    });
    expect(r.summaryText, isNull);
  });

  test('summaryText round-trip:toJson→fromJson 保真', () {
    final rec = Recording(
      id: 'recmd',
      source: RecSource.live,
      audioPath: '/x/recmd.mp3',
      title: '带纪要',
      durationMs: 1000,
      status: RecStatus.done,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1700000003000),
      summaryText: '## 叙事\n达成共识\n## 决定\n- 预算80万',
    );
    final back = Recording.fromJson(rec.toJson());
    expect(back.summaryText, contains('达成共识'));
    expect(back.summaryText, contains('## 决定'));
  });
}
