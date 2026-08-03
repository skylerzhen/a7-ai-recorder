import '../ai/ai_models.dart';

/// 当前播放位置对应的转写段下标 = startMs ≤ positionMs 的段里 startMs 最大的那个。
/// 用于「播放时高亮当前段」;首段之前 / 空列表返回 -1。无 startMs 的段跳过。
int currentSegmentIndex(List<AiTranscriptSeg> segs, int positionMs) {
  int best = -1;
  int bestStart = -1;
  for (int i = 0; i < segs.length; i++) {
    final s = segs[i].startMs;
    if (s == null) continue;
    if (s <= positionMs && s >= bestStart) {
      bestStart = s;
      best = i;
    }
  }
  return best;
}
