import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/audio/ogg_opus_muxer.dart';

/// 走一遍 Ogg 页(用 segment_table 算页长),返回每页 header_type;顺带校验都以 "OggS" 起。
List<int> _walk(Uint8List ogg) {
  final types = <int>[];
  var p = 0;
  while (p + 27 <= ogg.length) {
    final isOggS = ogg[p] == 0x4f && ogg[p + 1] == 0x67 && ogg[p + 2] == 0x67 && ogg[p + 3] == 0x53;
    if (!isOggS) break;
    final segs = ogg[p + 26];
    if (p + 27 + segs > ogg.length) break;
    var dataLen = 0;
    for (var k = 0; k < segs; k++) {
      dataLen += ogg[p + 27 + k];
    }
    types.add(ogg[p + 5]);
    p += 27 + segs + dataLen;
  }
  return types;
}

List<int> _records(int n) {
  final b = <int>[];
  for (var i = 0; i < n; i++) {
    b.addAll([0, 0, 0, 80]); // [0:4] 大端 len=80
    b.addAll([0, 0, 0, i & 0xFF]); // [4:8] 序号
    b.addAll(List.filled(80, 0xAB)); // [8:88] 80B 包
  }
  return b;
}

void main() {
  test('空 / 不足一条记录 → 空输出', () {
    expect(OggOpusMuxer.mux(const []), isEmpty);
    expect(OggOpusMuxer.mux(List.filled(50, 0)), isEmpty);
  });

  test('3 条 → 合法 Ogg-Opus:OggS 起、含 OpusHead/OpusTags、有 BOS+EOS', () {
    final ogg = OggOpusMuxer.mux(_records(3));
    expect(String.fromCharCodes(ogg.sublist(0, 4)), 'OggS');
    final s = String.fromCharCodes(ogg);
    expect(s.contains('OpusHead'), isTrue);
    expect(s.contains('OpusTags'), isTrue);
    final types = _walk(ogg);
    expect(types.length, 3); // BOS(head) + tags + 1 音频页
    expect(types.first & 0x02, 0x02); // 首页 BOS
    expect(types.last & 0x04, 0x04); // 末页 EOS
  });

  test('120 条 → BOS+Tags+ceil(120/50)=3 音频页 = 5 页,且整页可走通', () {
    final ogg = OggOpusMuxer.mux(_records(120));
    final types = _walk(ogg);
    expect(types.length, 5);
    expect(types.where((t) => t & 0x04 != 0).length, 1); // 恰一个 EOS
  });
}
