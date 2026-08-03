import unittest

from a7ble.advert import parse_manufacturer_blob, parse_from_bleak


class TestParseManufacturerBlob(unittest.TestCase):
    def test_decode_protocol_example(self):
        # 协议图实测例子: 1611 50c0f013d4c2 46413948413030363636
        blob = bytes.fromhex("161150c0f013d4c246413948413030363636")
        info = parse_manufacturer_blob(blob)
        self.assertEqual(info.company_id, 0x1116)
        self.assertEqual(info.mac, "50:c0:f0:13:d4:c2")
        self.assertEqual(info.sn, "FA9HA00666")


class TestParseFromBleak(unittest.TestCase):
    def test_keyed_by_company_id(self):
        # bleak 给的是 {company_id: payload(MAC+SN)}
        payload = bytes.fromhex("50c0f013d4c246413948413030363636")
        info = parse_from_bleak({0x1116: payload})
        self.assertIsNotNone(info)
        self.assertEqual(info.mac, "50:c0:f0:13:d4:c2")
        self.assertEqual(info.sn, "FA9HA00666")

    def test_missing_company_returns_none(self):
        self.assertIsNone(parse_from_bleak({0x004C: b"\x01\x02"}))


if __name__ == "__main__":
    unittest.main()
