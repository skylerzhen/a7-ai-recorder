import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';

// 协议补全:对账真机探针(web/e2e.py、stop.py、status.py、record10.py)的字节布局。
List<int> _name14(String s) {
  final b = List<int>.filled(14, 0);
  for (int i = 0; i < s.length && i < 14; i++) {
    b[i] = s.codeUnitAt(i);
  }
  return b;
}

void main() {
  group('0x04 setTime encode (matches e2e.py: [year-2000,M,D,h,m,s])', () {
    test('encodes year-2000 + month..second as 6 bytes', () {
      final f = parseFrame(setTime(DateTime(2026, 6, 18, 14, 5, 9)));
      expect(f.cmd, 0x04);
      expect(f.data, [26, 6, 18, 14, 5, 9]);
    });

    test('clamps a pre-2000 year to a single non-negative byte', () {
      final f = parseFrame(setTime(DateTime(1999, 1, 1, 0, 0, 0)));
      expect(f.data[0], 0); // never negative on the wire
    });
  });

  group('0x07 stop / 0x15 rec-info decode (00 + name14 + size4 BE + type + needSync)', () {
    test('decodes a full stop reply', () {
      final data = <int>[
        0x00,
        ..._name14('REC0001.mp3'),
        0x00, 0x17, 0x70, 0x00, // 1536000 big-endian
        0x01, // type
        0x00, // needSync
      ];
      final r = decodeRecFileInfo(data);
      expect(r.ok, isTrue);
      expect(r.name, 'REC0001.mp3');
      expect(r.size, 1536000);
      expect(r.type, 1);
      expect(r.needSync, 0);
    });

    test('tolerates a short reply (no type / needSync)', () {
      final data = <int>[0x00, ..._name14('A.mp3'), 0x00, 0x00, 0x00, 0x64];
      final r = decodeRecFileInfo(data);
      expect(r.ok, isTrue);
      expect(r.name, 'A.mp3');
      expect(r.size, 100);
      expect(r.type, -1);
      expect(r.needSync, -1);
    });

    test('status != 0 means not-ok', () {
      final r = decodeRecFileInfo(<int>[0x01, ..._name14(''), 0, 0, 0, 0]);
      expect(r.ok, isFalse);
    });
  });

  group('0x0b getFile reply decode (00 + size4 BE)', () {
    test('reads the declared file size (real downloaded.mp3 = 831782)', () {
      // 831782 = 0x000CB126 big-endian
      final r = decodeGetFileReply(<int>[0x00, 0x00, 0x0C, 0xB1, 0x26]);
      expect(r.ok, isTrue);
      expect(r.size, 831782);
    });
  });

  group('0x0f status report decode', () {
    test('splits leading event byte from payload, preserves raw', () {
      final r = decodeStatusReport(<int>[0x02, 0xAA, 0xBB]);
      expect(r.event, 0x02);
      expect(r.payload, [0xAA, 0xBB]);
      expect(r.raw, [0x02, 0xAA, 0xBB]);
    });

    // M3-gate 真机抓到 3 次主动推送 5c/5b/5a → byte[1]=电量(92/91/90 单调下降,与 0x05 吻合)。
    test('real push: byte[1] is battery (hardware-confirmed)', () {
      final r = decodeStatusReport(<int>[
        0x00, 0x5c, 0x01, 0x01, 0x00, 0x09, 0xff, 0xff, 0x03, //
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      ]);
      expect(r.event, 0x00);
      expect(r.battery, 0x5c); // 92%
      expect(r.raw.length, 20);
    });
  });

  group('ack helper (settings / record control reply: data[0]==0x00)', () {
    test('0x00 is ok, others / empty are not', () {
      expect(isOkReply(const [0x00]), isTrue);
      expect(isOkReply(const [0x01]), isFalse);
      expect(isOkReply(const []), isFalse);
    });
  });
}
