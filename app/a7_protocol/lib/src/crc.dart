/// CRC-16/ARC (poly reflected 0xA001, init 0, refin/refout=true).
///
/// Checksum range = frame head .. data. On the wire it is appended
/// LITTLE-ENDIAN (low byte first), verified on real hardware. (The
/// "big-endian" wording in a7ble/crc.py's docstring is stale — trust this.)
int crc16Arc(List<int> data) {
  int crc = 0;
  for (final b in data) {
    crc ^= (b & 0xFF);
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : (crc >> 1);
    }
  }
  return crc & 0xFFFF;
}
