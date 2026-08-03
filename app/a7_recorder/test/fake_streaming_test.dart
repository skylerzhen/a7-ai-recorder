import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:a7_protocol/a7_protocol.dart';

import 'package:a7_recorder/ble/fake_streaming_transport.dart';

// 用真机采样字节驱动 FakeStreamingTransport,验证它按协议「回 0x0b+size → B0B4 流」
// 行为正确,且重组结果与原文件逐字节相同(端到端,非合成数据)。
void main() {
  final fileBytes = File('assets/downloaded.mp3').readAsBytesSync();
  final rtBytes = File('assets/live_b3.mp3').readAsBytesSync();

  FakeStreamingTransport make() => FakeStreamingTransport(
        fileBytes: fileBytes,
        realtimeBytes: rtBytes,
        realtimeTick: Duration.zero,
        fileTick: Duration.zero,
      );

  test('连上即自动推真 B0B3 实时流(逐字节一致)', () async {
    final t = make();
    final got = <int>[];
    final done = Completer<void>();
    final sub = t.realtime.listen((b) {
      got.addAll(b);
      if (got.length >= rtBytes.length && !done.isCompleted) done.complete();
    });
    await t.connect('x');
    await done.future.timeout(const Duration(seconds: 5));
    await sub.cancel();

    expect(got.length, rtBytes.length);
    expect(got, rtBytes);
    await t.dispose();
  });

  test('0x0b → 回 size 再推 B0B4;重组==真文件(831782B 逐字节)', () async {
    final t = make();
    await t.connect('x');

    GetFileReply? reply;
    FileReassembler? asm;
    final completed = Completer<FileReassembler>();
    final cmdSub = t.cmdReplies.listen((bytes) {
      final f = parseFrame(bytes);
      if (f.crcOk && f.cmd == cmdGetFile) {
        reply = decodeGetFileReply(f.data);
        asm = FileReassembler(reply!.size);
      }
    });
    final fileSub = t.fileData.listen((chunk) {
      asm?.addChunk(chunk);
      if (asm != null && asm!.isComplete && !completed.isCompleted) {
        completed.complete(asm);
      }
    });

    await t.writeCommand(getFile('REC.mp3', seek: 0));
    final asmDone = await completed.future.timeout(const Duration(seconds: 15));
    await cmdSub.cancel();
    await fileSub.cancel();

    expect(reply!.ok, isTrue);
    expect(reply!.size, fileBytes.length); // 831782
    expect(asmDone.bytes, fileBytes); // 逐字节相同
    await t.dispose();
  });

  test('getFile(seek) 只推尾部(断点续传)', () async {
    final t = make();
    await t.connect('x');
    const seek = 100000;
    final got = <int>[];
    final done = Completer<void>();
    final fileSub = t.fileData.listen((c) {
      got.addAll(c);
      if (got.length >= fileBytes.length - seek && !done.isCompleted) {
        done.complete();
      }
    });

    await t.writeCommand(getFile('REC.mp3', seek: seek));
    await done.future.timeout(const Duration(seconds: 15));
    await fileSub.cancel();

    expect(got.length, fileBytes.length - seek);
    expect(got, fileBytes.sublist(seek));
    await t.dispose();
  });
}
