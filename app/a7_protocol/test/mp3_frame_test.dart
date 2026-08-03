import 'dart:io';

import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';

// MP3 帧头算帧长,供无界实时播放器按帧边界丢最旧(背压)。
// 真机样本 = MPEG-2 L3 32kbps/16kHz → 144B/帧(已用 web/downloaded.mp3 在 0/144/288 验证)。
void main() {
  group('mp3FrameLength', () {
    test('real MPEG-2 L3 header (ff f3 48 c4) = 144 bytes', () {
      expect(mp3FrameLength(const [0xFF, 0xF3, 0x48, 0xC4]), 144);
    });

    test('MPEG-1 L3 128kbps/44100 (ff fb 90 00) = 417 bytes', () {
      expect(mp3FrameLength(const [0xFF, 0xFB, 0x90, 0x00]), 417);
    });

    test('padding bit adds 1 byte', () {
      expect(mp3FrameLength(const [0xFF, 0xFB, 0x92, 0x00]), 418);
    });

    test('not a frame sync → 0', () {
      expect(mp3FrameLength(const [0x00, 0xF3, 0x48, 0xC4]), 0);
    });

    test('free bitrate (index 0) → 0', () {
      expect(mp3FrameLength(const [0xFF, 0xF3, 0x08, 0xC4]), 0);
    });

    test('bad bitrate (index 15) → 0', () {
      expect(mp3FrameLength(const [0xFF, 0xF3, 0xF8, 0xC4]), 0);
    });

    test('reserved sample-rate (index 3) → 0', () {
      expect(mp3FrameLength(const [0xFF, 0xF3, 0x4C, 0xC4]), 0);
    });

    test('too short → 0', () {
      expect(mp3FrameLength(const [0xFF, 0xF3]), 0);
    });
  });

  group('mp3BitrateBps', () {
    test('real MPEG-2 L3 = 32000 bps', () {
      expect(mp3BitrateBps(const [0xFF, 0xF3, 0x48, 0xC4]), 32000);
    });
    test('MPEG-1 L3 = 128000 bps', () {
      expect(mp3BitrateBps(const [0xFF, 0xFB, 0x90, 0x00]), 128000);
    });
    test('invalid header → 0', () {
      expect(mp3BitrateBps(const [0x00, 0x00, 0x00, 0x00]), 0);
    });
  });

  test('walks consecutive frame boundaries in the real file (0,144,288)', () {
    final b = File('test/fixtures/downloaded.mp3').readAsBytesSync();
    int pos = 0;
    for (int i = 0; i < 5; i++) {
      final len = mp3FrameLength(b.sublist(pos, pos + 4));
      expect(len, 144, reason: 'frame $i at offset $pos');
      pos += len;
      // 下一帧仍以同步头开始
      expect(b[pos] == 0xFF && (b[pos + 1] & 0xE0) == 0xE0, isTrue,
          reason: 'sync at offset $pos');
    }
  });
}
