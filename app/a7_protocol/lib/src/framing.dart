import 'crc.dart';

/// Frame: A0 0A | 01 | CMD | LEN | DATA[LEN] | CRC16(2B little-endian).
/// CRC range = head .. data.
const List<int> kFrameHead = [0xA0, 0x0A];
const int kFrameVersion = 0x01;

class Frame {
  final int cmd;
  final List<int> data;
  final bool crcOk;
  final int version;
  final List<int> raw;

  const Frame({
    required this.cmd,
    required this.data,
    required this.crcOk,
    required this.version,
    required this.raw,
  });
}

List<int> buildFrame(int cmd, [List<int> data = const []]) {
  if (cmd < 0 || cmd > 0xFF) {
    throw ArgumentError('cmd out of range 0..255');
  }
  if (data.length > 0xFF) {
    throw ArgumentError('data length exceeds 255');
  }
  final body = <int>[
    ...kFrameHead,
    kFrameVersion,
    cmd & 0xFF,
    data.length & 0xFF,
    ...data.map((b) => b & 0xFF),
  ];
  final crc = crc16Arc(body);
  return <int>[...body, crc & 0xFF, (crc >> 8) & 0xFF]; // little-endian
}

/// Mirrors a7ble's Python contract: malformed input (bad head / too short)
/// returns a Frame with crcOk=false and cmd=-1, NOT null.
Frame parseFrame(List<int> frame) {
  if (frame.length < 7 ||
      frame[0] != kFrameHead[0] ||
      frame[1] != kFrameHead[1]) {
    return Frame(
      cmd: -1,
      data: const [],
      crcOk: false,
      version: -1,
      raw: List<int>.unmodifiable(frame),
    );
  }
  final version = frame[2];
  final cmd = frame[3];
  final length = frame[4];
  final dataEnd = 5 + length;
  // Python slicing is lenient; clamp so malformed lengths don't throw.
  final clampedDataEnd = dataEnd > frame.length ? frame.length : dataEnd;
  final data = frame.sublist(5, clampedDataEnd);
  final body = frame.sublist(0, clampedDataEnd);
  final crcEnd = (dataEnd + 2) > frame.length ? frame.length : dataEnd + 2;
  final crcBytes =
      dataEnd <= frame.length ? frame.sublist(dataEnd, crcEnd) : const <int>[];
  final crcOk = crcBytes.length == 2 &&
      crc16Arc(body) == (crcBytes[0] | (crcBytes[1] << 8)); // little-endian
  return Frame(
    cmd: cmd,
    data: List<int>.unmodifiable(data),
    crcOk: crcOk,
    version: version,
    raw: List<int>.unmodifiable(frame),
  );
}
