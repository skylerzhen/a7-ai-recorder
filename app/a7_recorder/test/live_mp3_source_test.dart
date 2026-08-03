import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/audio/live_mp3_source.dart';

// 无界源的背压:没有播放器在拉流时,灌入远超上界的字节,源端缓冲必须被钳住且按帧丢最旧。
void main() {
  test('源端缓冲有界 + 溢出丢最旧整帧', () {
    // 一个合法 MPEG-2 L3 帧(头 ff f3 48 c4 → 帧长 144B)
    final frame = <int>[0xFF, 0xF3, 0x48, 0xC4, ...List<int>.filled(140, 0)];
    expect(frame.length, 144);

    final src = LiveMp3Source(maxBufferMs: 1000); // 32kbps → 上界≈4000B
    for (int i = 0; i < 200; i++) {
      src.add(frame); // 共 28800B,远超上界
    }

    expect(src.bitrateBps, 32000);
    expect(src.bufferedBytes, lessThanOrEqualTo(src.maxBufferBytes + 144));
    expect(src.droppedFrames, greaterThan(100)); // 绝大多数老帧被丢
  });
}
