import unittest

from a7ble.crc import crc16_arc


class TestCrc16Arc(unittest.TestCase):
    def test_check_vector(self):
        # 标准 CRC-16/ARC 校验值: "123456789" -> 0xBB3D
        self.assertEqual(crc16_arc(b"123456789"), 0xBB3D)

    def test_empty(self):
        self.assertEqual(crc16_arc(b""), 0x0000)

    def test_single_byte_zero(self):
        self.assertEqual(crc16_arc(b"\x00"), 0x0000)

    def test_single_byte_one(self):
        self.assertEqual(crc16_arc(b"\x01"), 0xC0C1)


if __name__ == "__main__":
    unittest.main()
