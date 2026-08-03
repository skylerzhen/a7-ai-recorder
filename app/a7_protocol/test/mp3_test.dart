import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';

// MP3 帧同步 = 11 bit 全 1:第一字节 0xFF,第二字节高 3 bit 全 1 → (b1 & 0xE0) == 0xE0。
// 与 a7ble 探针 record10.py 的裁头判据一致(覆盖真机样本的 0xFF 0xF3)。
void main() {
  group('mp3SyncOffset', () {
    test('finds sync at offset 0 when already clean (real header ff f3)', () {
      expect(mp3SyncOffset(const [0xFF, 0xF3, 0x48, 0xC4]), 0);
    });

    test('skips leading garbage to first sync', () {
      expect(mp3SyncOffset(const [0x00, 0x11, 0x22, 0xFF, 0xF3, 0x48]), 3);
    });

    test('ignores a lone 0xFF not followed by a valid sync byte', () {
      // index 0 is 0xFF but next is 0x00 (not sync); real sync starts at index 2
      expect(mp3SyncOffset(const [0xFF, 0x00, 0xFF, 0xFB, 0x90, 0x00]), 2);
    });

    test('returns -1 when no frame sync present', () {
      expect(mp3SyncOffset(const [0x00, 0x01, 0x02, 0x03]), -1);
    });
  });

  group('trimToMp3Sync', () {
    test('drops the leading bytes before the first sync', () {
      final out = trimToMp3Sync(const [0xAA, 0xBB, 0xFF, 0xF3, 0x48, 0xC4]);
      expect(out, const [0xFF, 0xF3, 0x48, 0xC4]);
    });

    test('leaves an already-clean buffer unchanged', () {
      const clean = [0xFF, 0xF3, 0x48, 0xC4, 0x11, 0x22];
      expect(trimToMp3Sync(clean), clean);
    });

    test('returns input unchanged when no sync is found (never loses data)', () {
      const junk = [0x00, 0x01, 0x02];
      expect(trimToMp3Sync(junk), junk);
    });
  });
}
