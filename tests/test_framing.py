import unittest

from a7ble.crc import crc16_arc
from a7ble.framing import build_frame, parse_frame


class TestBuildFrame(unittest.TestCase):
    def test_structure_no_data(self):
        frame = build_frame(0x05)
        self.assertEqual(frame[:3], b"\xA0\x0A\x01")  # head A0 0A + version 01
        self.assertEqual(frame[3], 0x05)              # cmd
        self.assertEqual(frame[4], 0x00)              # len
        self.assertEqual(len(frame), 7)               # 2+1+1+1 + crc(2)

    def test_crc_appended_little_endian(self):
        # 真机实测: CRC 在线上是小端(低字节在前)。协议图标的"大端"是错的。
        frame = build_frame(0x05)
        body = frame[:-2]
        crc = crc16_arc(body)
        self.assertEqual(frame[-2], crc & 0xFF)          # 低字节在前 = 小端
        self.assertEqual(frame[-1], (crc >> 8) & 0xFF)

    def test_data_sets_len(self):
        frame = build_frame(0x06, b"ABC")
        self.assertEqual(frame[3], 0x06)
        self.assertEqual(frame[4], 0x03)
        self.assertEqual(frame[5:8], b"ABC")


class TestParseFrame(unittest.TestCase):
    def test_roundtrip_ok(self):
        parsed = parse_frame(build_frame(0x06, b"hello"))
        self.assertTrue(parsed.crc_ok)
        self.assertEqual(parsed.cmd, 0x06)
        self.assertEqual(parsed.data, b"hello")

    def test_detects_corrupt_data(self):
        frame = bytearray(build_frame(0x06, b"hello"))
        frame[5] ^= 0xFF
        self.assertFalse(parse_frame(bytes(frame)).crc_ok)

    def test_detects_bad_head(self):
        self.assertFalse(parse_frame(b"\x00\x00\x01\x05\x00\x00\x00").crc_ok)


class TestRealCapturedFrame(unittest.TestCase):
    # 真机 0x05 设备信息回包 (A7 "X Note", 2026-06-17)
    RAW = bytes.fromhex(
        ("a0 0a 01 05 34 00 00 ee 12 00 00 ee 0f 00 14 01 01 00 04 01 01 ff "
         "78 69 6e 6b 5f 74 65 73 74 00 00 00 00 00 00 00 00 00 00 00 00 00 "
         "09 ff 03 00 00 00 00 00 00 00 00 00 00 d9 f4").replace(" ", "")
    )

    def test_parses_with_valid_crc(self):
        f = parse_frame(self.RAW)
        self.assertTrue(f.crc_ok)
        self.assertEqual(f.cmd, 0x05)
        self.assertEqual(len(f.data), 0x34)


if __name__ == "__main__":
    unittest.main()
