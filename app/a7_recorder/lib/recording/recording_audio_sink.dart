import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 录音时把音频流式写入临时文件，避免 `_audioBuf` 无限占内存。
class RecordingAudioSink {
  RandomAccessFile? _file;
  String? _tempPath;
  int bytesWritten = 0;

  bool get hasData => bytesWritten > 0;
  String? get tempPath => _tempPath;

  Future<void> open({required bool pcm}) async {
    await close();
    final dir = await getTemporaryDirectory();
    _tempPath = '${dir.path}/live_${DateTime.now().millisecondsSinceEpoch}.${pcm ? 'pcm' : 'raw'}';
    _file = await File(_tempPath!).open(mode: FileMode.write);
    bytesWritten = 0;
  }

  void write(List<int> chunk) {
    if (_file == null || chunk.isEmpty) return;
    _file!.writeFromSync(chunk);
    bytesWritten += chunk.length;
  }

  Future<void> close() async {
    try {
      await _file?.flush();
      await _file?.close();
    } catch (_) {}
    _file = null;
  }

  Future<void> deleteTemp() async {
    final p = _tempPath;
    _tempPath = null;
    if (p == null) return;
    try {
      final f = File(p);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 手机 PCM → 带 RIFF 头的 WAV，分块读写，不把整段载入内存。
  Future<void> writeWavFromPcmFile(String outPath, {int sampleRate = 16000}) async {
    final pcmPath = _tempPath;
    if (pcmPath == null || bytesWritten == 0) {
      throw StateError('无 PCM 数据可写');
    }
    final out = await File(outPath).open(mode: FileMode.write);
    try {
      out.writeFromSync(_wavHeader(bytesWritten, sampleRate: sampleRate));
      final pcm = await File(pcmPath).open(mode: FileMode.read);
      try {
        const chunk = 65536;
        final buf = Uint8List(chunk);
        var left = bytesWritten;
        while (left > 0) {
          final n = await pcm.readInto(buf, 0, left < chunk ? left : chunk);
          if (n <= 0) break;
          out.writeFromSync(buf, 0, n);
          left -= n;
        }
      } finally {
        await pcm.close();
      }
      await out.flush();
    } finally {
      await out.close();
    }
  }

  /// 非 PCM 源：直接把临时 raw 文件复制到目标路径。
  Future<void> copyRawTo(String outPath) async {
    final src = _tempPath;
    if (src == null || bytesWritten == 0) {
      throw StateError('无音频数据可写');
    }
    await File(src).copy(outPath);
  }

  static Uint8List _wavHeader(int dataLen, {int sampleRate = 16000, int channels = 1, int bits = 16}) {
    final byteRate = sampleRate * channels * bits ~/ 8;
    final blockAlign = channels * bits ~/ 8;
    final b = BytesBuilder();
    void s(String v) => b.add(v.codeUnits);
    void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    s('RIFF');
    u32(36 + dataLen);
    s('WAVE');
    s('fmt ');
    u32(16);
    u16(1);
    u16(channels);
    u32(sampleRate);
    u32(byteRate);
    u16(blockAlign);
    u16(bits);
    s('data');
    u32(dataLen);
    return b.toBytes();
  }
}
