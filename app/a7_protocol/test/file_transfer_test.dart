import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:a7_protocol/a7_protocol.dart';

// 硬指标:把真机离线下载样本 downloaded.mp3 按 ~243B/片喂进 FileReassembler,
// 重组结果必须与原文件逐字节相同 → md5 一致。验收方会复算同一个 md5。
const String kDownloadedMd5 = '15000c86456236f771ec4bb7c57e9d22';

String _md5(List<int> b) => md5.convert(b).toString();

void _feed(FileReassembler r, List<int> data, {int chunk = 243}) {
  for (int i = 0; i < data.length; i += chunk) {
    final end = (i + chunk) > data.length ? data.length : i + chunk;
    r.addChunk(data.sublist(i, end));
  }
}

void main() {
  final original =
      File('test/fixtures/downloaded.mp3').readAsBytesSync();

  test('fixture itself is the real 831782B sample (md5 sanity)', () {
    expect(original.length, 831782);
    expect(_md5(original), kDownloadedMd5);
  });

  test('reassembles 243B B0B4 chunks byte-for-byte (md5 == real file)', () {
    final r = FileReassembler(original.length);
    _feed(r, original, chunk: 243);

    expect(r.isComplete, isTrue);
    expect(r.received, original.length);
    expect(_md5(r.bytes), kDownloadedMd5);
  });

  test('exposes progress while incomplete', () {
    final r = FileReassembler(original.length);
    final half = original.length ~/ 2;
    _feed(r, original.sublist(0, half), chunk: 243);

    expect(r.isComplete, isFalse);
    expect(r.received, half);
    expect(r.progress, closeTo(0.5, 0.01));
  });

  test('resumes from a seek offset and still matches byte-for-byte', () {
    const cut = 100000;
    final r = FileReassembler(original.length);
    _feed(r, original.sublist(0, cut), chunk: 243);

    // 断点:下次应从已收字节数处续传(getFile seek = nextSeek)
    expect(r.nextSeek, cut);
    expect(r.isComplete, isFalse);

    // 模拟重新 getFile(seek: cut) 后,设备从 cut 处继续推
    _feed(r, original.sublist(cut), chunk: 243);

    expect(r.isComplete, isTrue);
    expect(_md5(r.bytes), kDownloadedMd5);
  });

  test('clips overflow so output never exceeds declared size', () {
    final r = FileReassembler(10);
    r.addChunk(List<int>.filled(8, 0xAA));
    r.addChunk(List<int>.filled(8, 0xBB)); // 8+8=16 > 10 → 只收到 10

    expect(r.received, 10);
    expect(r.bytes.length, 10);
    expect(r.isComplete, isTrue);
    expect(r.bytes, [0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xBB, 0xBB]);
  });
}
