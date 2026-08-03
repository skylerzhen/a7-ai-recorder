import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';
import 'hex_util.dart';

// Ported 1:1 from a7ble/tests/test_framing.py
void main() {
  group('buildFrame', () {
    test('structure with no data', () {
      final frame = buildFrame(0x05);
      expect(frame.sublist(0, 3), [0xA0, 0x0A, 0x01]); // head A0 0A + version 01
      expect(frame[3], 0x05); // cmd
      expect(frame[4], 0x00); // len
      expect(frame.length, 7); // 2+1+1+1 + crc(2)
    });

    test('CRC appended little-endian (low byte first)', () {
      // Real hardware: CRC on the wire is little-endian. The protocol diagram's
      // "big-endian" is wrong (so are the stale docstrings in crc.py/framing.py).
      final frame = buildFrame(0x05);
      final body = frame.sublist(0, frame.length - 2);
      final crc = crc16Arc(body);
      expect(frame[frame.length - 2], crc & 0xFF); // low byte first = little-endian
      expect(frame[frame.length - 1], (crc >> 8) & 0xFF);
    });

    test('data sets len', () {
      final frame = buildFrame(0x06, 'ABC'.codeUnits);
      expect(frame[3], 0x06);
      expect(frame[4], 0x03);
      expect(frame.sublist(5, 8), 'ABC'.codeUnits);
    });
  });

  group('parseFrame', () {
    test('roundtrip ok', () {
      final parsed = parseFrame(buildFrame(0x06, 'hello'.codeUnits));
      expect(parsed.crcOk, isTrue);
      expect(parsed.cmd, 0x06);
      expect(parsed.data, 'hello'.codeUnits);
    });

    test('detects corrupt data', () {
      final frame = List<int>.of(buildFrame(0x06, 'hello'.codeUnits));
      frame[5] ^= 0xFF;
      expect(parseFrame(frame).crcOk, isFalse);
    });

    test('detects bad head', () {
      // Contract (matches Python): bad head returns a Frame with crcOk=false,
      // NOT null — so this assertion ports literally.
      expect(parseFrame([0x00, 0x00, 0x01, 0x05, 0x00, 0x00, 0x00]).crcOk, isFalse);
    });
  });

  group('real captured frame (A7 "X Note", 0x05 device info, 2026-06-17)', () {
    final raw = hx('a0 0a 01 05 34 00 00 ee 12 00 00 ee 0f 00 14 01 01 00 04 01 01 ff '
        '78 69 6e 6b 5f 74 65 73 74 00 00 00 00 00 00 00 00 00 00 00 00 00 '
        '09 ff 03 00 00 00 00 00 00 00 00 00 00 d9 f4');

    test('parses with valid CRC', () {
      final f = parseFrame(raw);
      expect(f.crcOk, isTrue);
      expect(f.cmd, 0x05);
      expect(f.data.length, 0x34);
    });
  });
}
