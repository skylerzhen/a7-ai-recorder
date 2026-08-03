import 'dart:typed_data';

/// Ogg-Opus 增量编码器:把 80B Opus 包逐页封进 Ogg 容器(just_audio/media3 原生可解码播放,无原生依赖)。
///
/// 离线整封用 [OggOpusMuxer.mux];实时边录边听用 [`LiveOggSource`](持续 `header()` + `audio()`)。
/// Ogg granule 一律按 48kHz 计:每 20ms 包 = 960 样本。pre-skip=0(设备包非 libopus 编码,不裁前导)。
class OggOpusEncoder {
  static const int _serial = 0x0A37A7; // 任意固定 bitstream serial
  static const int _samplesPerPacket = 960;
  int _seq = 0;
  int _granule = 0;
  bool _headerDone = false;

  /// 头两页(OpusHead BOS + OpusTags);只第一次返回字节,之后返回空。
  List<int> header() {
    if (_headerDone) return const [];
    _headerDone = true;
    return <int>[
      ..._page(0x02, 0, _seq++, [_opusHead()]),
      ..._page(0x00, 0, _seq++, [_opusTags()]),
    ];
  }

  /// 一页音频(若干 80B 包);[eos] 为末页(EOS 标志)。
  List<int> audio(List<List<int>> packets, {bool eos = false}) {
    _granule += packets.length * _samplesPerPacket;
    return _page(eos ? 0x04 : 0x00, _granule, _seq++, packets);
  }

  static List<int> _opusHead() {
    final b = BytesBuilder();
    b.add('OpusHead'.codeUnits);
    b.addByte(1); // version
    b.addByte(1); // channels = mono
    b.add(_le16(0)); // pre-skip = 0
    b.add(_le32(16000)); // input sample rate(信息位)
    b.add(_le16(0)); // output gain
    b.addByte(0); // channel mapping family 0
    return b.toBytes();
  }

  static List<int> _opusTags() {
    final b = BytesBuilder();
    b.add('OpusTags'.codeUnits);
    const vendor = 'a7_recorder';
    b.add(_le32(vendor.length));
    b.add(vendor.codeUnits);
    b.add(_le32(0));
    return b.toBytes();
  }

  static Uint8List _page(int headerType, int granule, int seq, List<List<int>> packets) {
    final segTable = <int>[];
    final data = <int>[];
    for (final p in packets) {
      var n = p.length;
      while (n >= 255) {
        segTable.add(255);
        n -= 255;
      }
      segTable.add(n);
      data.addAll(p);
    }
    final page = BytesBuilder();
    page.add('OggS'.codeUnits);
    page.addByte(0); // version
    page.addByte(headerType);
    page.add(_le64(granule));
    page.add(_le32(_serial));
    page.add(_le32(seq));
    page.add(_le32(0)); // CRC 占位
    page.addByte(segTable.length);
    page.add(segTable);
    page.add(data);
    final bytes = page.toBytes();
    final crc = _oggCrc32(bytes);
    bytes[22] = crc & 0xFF;
    bytes[23] = (crc >> 8) & 0xFF;
    bytes[24] = (crc >> 16) & 0xFF;
    bytes[25] = (crc >> 24) & 0xFF;
    return bytes;
  }

  // Ogg CRC-32:poly 0x04C11DB7,init 0,无反射,无 final xor。
  static final Uint32List _crcTable = _buildCrcTable();
  static Uint32List _buildCrcTable() {
    final t = Uint32List(256);
    for (var i = 0; i < 256; i++) {
      var r = (i << 24) & 0xFFFFFFFF;
      for (var j = 0; j < 8; j++) {
        r = (r & 0x80000000) != 0 ? ((r << 1) ^ 0x04C11DB7) & 0xFFFFFFFF : (r << 1) & 0xFFFFFFFF;
      }
      t[i] = r;
    }
    return t;
  }

  static int _oggCrc32(List<int> data) {
    var crc = 0;
    for (final b in data) {
      crc = (((crc << 8) & 0xFFFFFFFF) ^ _crcTable[((crc >> 24) ^ b) & 0xFF]) & 0xFFFFFFFF;
    }
    return crc;
  }

  static List<int> _le16(int v) => [v & 0xFF, (v >> 8) & 0xFF];
  static List<int> _le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
  static List<int> _le64(int v) => [
        v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF,
        (v >> 32) & 0xFF, (v >> 40) & 0xFF, (v >> 48) & 0xFF, (v >> 56) & 0xFF,
      ];
}

/// 离线:88B 记录流 → Ogg-Opus 字节(本地 .opus 文件可播,见 detail_screen)。
class OggOpusMuxer {
  static const int _recordLen = 88;
  static const int _packetOff = 8; // 跳过 [0:4]len + [4:8]序号
  static const int _packetLen = 80;
  static const int _packetsPerPage = 50;

  /// 88B 记录流 → Ogg-Opus;不是合法流(凑不出一条记录)时返回空。
  static Uint8List mux(List<int> records) {
    final packets = <List<int>>[];
    for (var off = 0; off + _recordLen <= records.length; off += _recordLen) {
      packets.add(records.sublist(off + _packetOff, off + _packetOff + _packetLen));
    }
    if (packets.isEmpty) return Uint8List(0);
    final enc = OggOpusEncoder();
    final out = BytesBuilder();
    out.add(enc.header());
    var done = 0;
    while (done < packets.length) {
      final end = (done + _packetsPerPage) > packets.length ? packets.length : done + _packetsPerPage;
      final chunk = packets.sublist(done, end);
      done = end;
      out.add(enc.audio(chunk, eos: done >= packets.length));
    }
    return out.toBytes();
  }
}
