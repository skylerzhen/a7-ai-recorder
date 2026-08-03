/// MP3 帧同步定位 / 裁前导。纯逻辑,零依赖。
///
/// A7「X Note」实时流(B0B3)/ 离线文件(B0B4)是 MPEG-2 L3,真机样本以 `FF F3` 开头。
/// 帧同步 = 11 bit 全 1:第一字节 0xFF,第二字节高 3 bit 全 1 → `(b1 & 0xE0) == 0xE0`。
/// 判据与 a7ble 探针 record10.py 一致(覆盖 0xFx 的 MPEG-1/2,以及 0xEx 的 MPEG-2.5)。

/// 返回首个 MP3 帧同步的下标;找不到返回 -1。
int mp3SyncOffset(List<int> bytes) {
  for (int i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0) return i;
  }
  return -1;
}

/// 裁掉首个帧同步之前的前导字节。找不到同步则原样返回(绝不丢数据)。
List<int> trimToMp3Sync(List<int> bytes) {
  final off = mp3SyncOffset(bytes);
  return off <= 0 ? bytes : bytes.sublist(off);
}

// MPEG 版本 / 层 / 比特率表(仅 Layer III,本设备用 MPEG-2 L3 32kbps/16kHz)。
// 比特率单位 kbps,index 0=free、15=bad(都视为非法→0)。
const List<int> _brV1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, -1];
const List<int> _brV2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, -1];
const List<int> _srV1 = [44100, 48000, 32000, -1];
const List<int> _srV2 = [22050, 24000, 16000, -1];
const List<int> _srV25 = [11025, 12000, 8000, -1];

class _Mp3Hdr {
  final int frameLength; // 字节
  final int bitrateBps; // bit/s
  const _Mp3Hdr(this.frameLength, this.bitrateBps);
}

/// 解析 MPEG Layer III 帧头;非法 / 非 L3 / 数据不足返回 null。
/// 帧长 = 系数 × 比特率(bps) ÷ 采样率(Hz) + padding。
/// 系数:MPEG-1 L3 = 144(1152 样本/帧);MPEG-2/2.5 L3 = 72(576 样本/帧)。
_Mp3Hdr? _parse(List<int> header) {
  if (header.length < 4) return null;
  final b0 = header[0], b1 = header[1], b2 = header[2];
  if (b0 != 0xFF || (b1 & 0xE0) != 0xE0) return null; // 同步

  final versionBits = (b1 >> 3) & 0x3; // 00=2.5 01=保留 10=2 11=1
  final layerBits = (b1 >> 1) & 0x3; //   00=保留 01=L3 10=L2 11=L1
  if (versionBits == 1) return null; // 保留版本
  if (layerBits != 0x1) return null; // 只处理 Layer III

  final brIndex = (b2 >> 4) & 0xF;
  final srIndex = (b2 >> 2) & 0x3;
  final padding = (b2 >> 1) & 0x1;
  if (srIndex == 3) return null; // 保留采样率

  final isV1 = versionBits == 3;
  final bitrateKbps = (isV1 ? _brV1L3 : _brV2L3)[brIndex];
  if (bitrateKbps <= 0) return null; // free / bad

  final sampleRate = switch (versionBits) {
    3 => _srV1[srIndex],
    2 => _srV2[srIndex],
    _ => _srV25[srIndex], // 0 = MPEG 2.5
  };
  if (sampleRate <= 0) return null;

  final coeff = isV1 ? 144 : 72;
  final bitrateBps = bitrateKbps * 1000;
  return _Mp3Hdr(coeff * bitrateBps ~/ sampleRate + padding, bitrateBps);
}

/// 由 4 字节帧头算 Layer III 帧长(字节);非法返回 0。
int mp3FrameLength(List<int> header) => _parse(header)?.frameLength ?? 0;

/// 由 4 字节帧头取比特率(bit/s);非法返回 0。供无界播放器按字节率节流出数。
int mp3BitrateBps(List<int> header) => _parse(header)?.bitrateBps ?? 0;
