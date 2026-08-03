import 'dart:typed_data';

/// B0B4 离线文件分片重组。纯逻辑,零依赖。
///
/// 用法:0x0b 取文件回包给出总大小 → `FileReassembler(size)`;每收到一片 B0B4
/// 调 [addChunk];[isComplete] 后 [bytes] 即完整文件(与设备端逐字节相同)。
/// 断点续传:中断后用 [nextSeek] 作为 `getFile(name, seek: nextSeek)` 的偏移,
/// 设备从该处续推,继续 [addChunk] 即可。
class FileReassembler {
  /// 0x0b 回包声明的文件总大小(字节)。
  final int totalSize;
  final Uint8List _buf;
  int _received = 0;

  FileReassembler(this.totalSize) : _buf = Uint8List(totalSize < 0 ? 0 : totalSize);

  /// 追加一片;超出声明大小的部分被裁掉(绝不越界 / 不超过 [totalSize])。
  void addChunk(List<int> chunk) {
    if (_received >= totalSize || chunk.isEmpty) return;
    final remaining = totalSize - _received;
    final take = chunk.length < remaining ? chunk.length : remaining;
    for (int i = 0; i < take; i++) {
      _buf[_received + i] = chunk[i] & 0xFF;
    }
    _received += take;
  }

  /// 已收字节数。
  int get received => _received;

  /// 续传偏移 = 已收字节数。
  int get nextSeek => _received;

  /// 0..1 进度;totalSize==0 视为已完成。
  double get progress => totalSize == 0 ? 1.0 : _received / totalSize;

  bool get isComplete => _received >= totalSize;

  /// 当前已重组字节(完成时即完整文件)。返回只增长的视图副本。
  Uint8List get bytes => Uint8List.sublistView(_buf, 0, _received);
}
