import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';
import 'hex_util.dart';

// Ported 1:1 from a7ble/tests/test_commands.py
void main() {
  group('encoders', () {
    test('device info is 0x05 with no data', () {
      final parsed = parseFrame(getDeviceInfo());
      expect(parsed.cmd, 0x05);
      expect(parsed.data, isEmpty);
    });

    test('start recording layout: name(14) + type(1)', () {
      final parsed = parseFrame(startRecording('REC001', 1));
      expect(parsed.cmd, 0x06);
      expect(parsed.data.length, 15);
      expect(parsed.data.sublist(0, 6), 'REC001'.codeUnits);
      expect(parsed.data.sublist(6, 14), List.filled(8, 0)); // null-padded to 14
      expect(parsed.data[14], 1); // type
    });

    test('get file layout: name(14) + seek(4)', () {
      final parsed = parseFrame(getFile('a.mp3', seek: 0x10));
      expect(parsed.cmd, 0x0B);
      expect(parsed.data.length, 18);
      expect(parsed.data.sublist(0, 5), 'a.mp3'.codeUnits);
    });

    test('name too long rejected', () {
      expect(() => startRecording('X' * 15, 0), throwsArgumentError);
    });

    test('get bind info is 0x02 with no data', () {
      final parsed = parseFrame(getBindInfo());
      expect(parsed.cmd, 0x02);
      expect(parsed.data, isEmpty);
    });

    test('bind is 0x03: data = 16B code + op (real firmware; NOT the manual 0x01)', () {
      final parsed = parseFrame(bind('183396'.codeUnits));
      expect(parsed.cmd, 0x03);
      expect(parsed.data.length, 17); // 16 code + 1 op
      expect(parsed.data.sublist(0, 6), '183396'.codeUnits);
      expect(parsed.data.sublist(6, 16), List.filled(10, 0)); // padded to 16
      expect(parsed.data[16], 0x00); // op = bind
    });

    test('get SN is 0x01', () {
      expect(parseFrame(getSn()).cmd, 0x01);
    });
  });

  group('file list decode', () {
    test('decodes entry: name(14) + size(4, big-endian) + type(1)', () {
      // name "a.mp3" padded to 14, then size 1000 (0x000003E8) big-endian, then type 0x00
      final entry = decodeFileListEntry(
        [...'a.mp3'.codeUnits, ...List.filled(9, 0), 0x00, 0x00, 0x03, 0xE8, 0x00],
      );
      expect(entry.name, 'a.mp3');
      expect(entry.size, 1000);
      expect(entry.type, 0);
    });
  });

  group('device info decode (A7 "X Note", 52B, 2026-06-17)', () {
    final data = hx('0000ee120000ee03011c010100040101ff78696e6b5f746573740000'
        '000000000000000000000009ff0300000000000000000000');

    test('decodes real capture', () {
      final di = decodeDeviceInfo(data);
      expect(di.totalMb, 60946);
      expect(di.freeMb, 60931);
      expect(di.charging, 1);
      expect(di.battery, 28);
      expect(di.recording, 1);
      expect(di.model, 'xink_test');
      expect(di.denoise, 9);
      expect(di.segment, 3);
    });
  });

  group('wifi 快传(新机 0x1B / 0x1F,真机 HCI 验通)', () {
    test('openWifi(open) = A0 0A 01 1B 01 01 + CRC;parse 回 cmd 0x1B / data [1]', () {
      final f = openWifi(open: true);
      final p = parseFrame(f);
      expect(p.crcOk, isTrue);
      expect(p.cmd, 0x1B);
      expect(p.data, [0x01]);
      expect(f.sublist(0, 6), [0xA0, 0x0A, 0x01, 0x1B, 0x01, 0x01]);
    });

    test('openWifi(close) payload = 00', () {
      expect(parseFrame(openWifi(open: false)).data, [0x00]);
    });

    test('decodeWifiInfo:18B = ssid(10)+pwd(8)', () {
      final payload = <int>[...'Doway_0078'.codeUnits, ...'Q95HA000'.codeUnits];
      final w = decodeWifiInfo(payload);
      expect(w.ssid, 'Doway_0078');
      expect(w.password, 'Q95HA000');
    });

    test('wifiApFromSn:SSID=Doway_+SN后4,密码=SN前8', () {
      final w = wifiApFromSn('Q95HA00078');
      expect(w.ssid, 'Doway_0078');
      expect(w.password, 'Q95HA000');
    });

    test('isWifiCapable:X95/AINOTE model 或 Q95 SN → 真;旧机 → 假', () {
      expect(isWifiCapable(model: 'X95-AINOTE'), isTrue);
      expect(isWifiCapable(sn: 'Q95HA00078'), isTrue);
      expect(isWifiCapable(model: 'xink_test', sn: 'FA9HA00001'), isFalse);
    });

    test('audioCodecOf:新机 opus / 旧机 mp3(同一套判据)', () {
      expect(audioCodecOf(model: 'X95-AINOTE'), 'opus');
      expect(audioCodecOf(sn: 'Q95HA00078'), 'opus');
      expect(audioCodecOf(model: 'X Note', sn: 'FA9HA00001'), 'mp3');
      expect(audioCodecOf(), 'mp3'); // 未知 → mp3(不误判旧机)
    });
  });
}
