import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';
import 'hex_util.dart';

// Ported 1:1 from a7ble/tests/test_advert.py
void main() {
  group('parseManufacturerBlob', () {
    test('decodes protocol example', () {
      // 1611 50c0f013d4c2 46413948413030363636
      final blob = hx('161150c0f013d4c246413948413030363636');
      final info = parseManufacturerBlob(blob);
      expect(info.companyId, 0x1116);
      expect(info.mac, '50:c0:f0:13:d4:c2');
      expect(info.sn, 'FA9HA00666');
    });
  });

  group('parseFromBleak', () {
    test('keyed by company id {companyId: payload(MAC+SN)}', () {
      final payload = hx('50c0f013d4c246413948413030363636');
      final info = parseFromBleak({0x1116: payload});
      expect(info, isNotNull);
      expect(info!.mac, '50:c0:f0:13:d4:c2');
      expect(info.sn, 'FA9HA00666');
    });

    test('missing company returns null', () {
      expect(parseFromBleak({0x004C: const [0x01, 0x02]}), isNull);
    });
  });
}
