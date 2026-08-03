import unittest

from a7ble import commands as C
from a7ble.framing import parse_frame


class TestEncoders(unittest.TestCase):
    def test_device_info_is_0x05_no_data(self):
        parsed = parse_frame(C.get_device_info())
        self.assertEqual(parsed.cmd, 0x05)
        self.assertEqual(parsed.data, b"")

    def test_start_recording_layout(self):
        parsed = parse_frame(C.start_recording("REC001", 1))
        self.assertEqual(parsed.cmd, 0x06)
        self.assertEqual(len(parsed.data), 15)              # name(14) + type(1)
        self.assertEqual(parsed.data[:6], b"REC001")
        self.assertEqual(parsed.data[6:14], b"\x00" * 8)    # null 补齐到 14
        self.assertEqual(parsed.data[14], 1)                # type

    def test_get_file_layout(self):
        parsed = parse_frame(C.get_file("a.mp3", seek=0x10))
        self.assertEqual(parsed.cmd, 0x0B)
        self.assertEqual(len(parsed.data), 18)              # name(14) + seek(4)
        self.assertEqual(parsed.data[:5], b"a.mp3")

    def test_name_too_long_rejected(self):
        with self.assertRaises(ValueError):
            C.start_recording("X" * 15, 0)

    def test_get_bind_info_is_0x02_no_data(self):
        parsed = parse_frame(C.get_bind_info())
        self.assertEqual(parsed.cmd, 0x02)
        self.assertEqual(parsed.data, b"")

    def test_bind_is_0x03_layout(self):
        # 实测:绑定命令是 0x03(非手册的 0x01);data = 16B码 + op
        parsed = parse_frame(C.bind(b"183396"))
        self.assertEqual(parsed.cmd, 0x03)
        self.assertEqual(len(parsed.data), 17)            # 16 code + 1 op
        self.assertEqual(parsed.data[:6], b"183396")
        self.assertEqual(parsed.data[6:16], b"\x00" * 10)  # 补齐到 16
        self.assertEqual(parsed.data[16], 0x00)            # op=绑定

    def test_get_sn_is_0x01(self):
        self.assertEqual(parse_frame(C.get_sn()).cmd, 0x01)


class TestFileListDecode(unittest.TestCase):
    def test_decode_entry(self):
        # 手册 J: name(14) + size(4,大端) + type(1)
        entry = C.decode_file_list_entry(
            b"a.mp3" + b"\x00" * 9 + (1000).to_bytes(4, "big") + b"\x00"
        )
        self.assertEqual(entry.name, "a.mp3")
        self.assertEqual(entry.size, 1000)
        self.assertEqual(entry.type, 0)


class TestDeviceInfoDecode(unittest.TestCase):
    # 真机 A7 "X Note" 的 0x05 设备信息 52B(2026-06-17)
    DATA = bytes.fromhex(
        "0000ee120000ee03011c010100040101ff78696e6b5f746573740000"
        "000000000000000000000009ff0300000000000000000000"
    )

    def test_decode_real(self):
        di = C.decode_device_info(self.DATA)
        self.assertEqual(di.total_mb, 60946)
        self.assertEqual(di.free_mb, 60931)
        self.assertEqual(di.charging, 1)
        self.assertEqual(di.battery, 28)
        self.assertEqual(di.recording, 1)
        self.assertEqual(di.model, "xink_test")
        self.assertEqual(di.denoise, 9)
        self.assertEqual(di.segment, 3)


if __name__ == "__main__":
    unittest.main()
