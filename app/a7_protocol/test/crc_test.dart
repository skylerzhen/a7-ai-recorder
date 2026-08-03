import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';

// Ported 1:1 from a7ble/tests/test_crc.py
void main() {
  group('crc16Arc', () {
    test('standard check vector "123456789" -> 0xBB3D', () {
      expect(crc16Arc('123456789'.codeUnits), 0xBB3D);
    });

    test('empty -> 0x0000', () {
      expect(crc16Arc(const []), 0x0000);
    });

    test('single byte 0x00 -> 0x0000', () {
      expect(crc16Arc(const [0x00]), 0x0000);
    });

    test('single byte 0x01 -> 0xC0C1', () {
      expect(crc16Arc(const [0x01]), 0xC0C1);
    });
  });
}
