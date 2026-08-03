import 'package:a7_protocol/a7_protocol.dart';

import '../ble/transport.dart';

enum A7Phase { idle, scanning, connecting, binding, ready, error }

/// App 的设备会话状态(不可变)。
class A7State {
  final A7Phase phase;
  final List<A7Scan> found; // 扫到的设备
  final A7Scan? device; // 当前连接的设备
  final DeviceInfo? info; // 0x05 解码
  final List<FileEntry> files; // 0x0a 解码
  final String? error;

  const A7State({
    this.phase = A7Phase.idle,
    this.found = const [],
    this.device,
    this.info,
    this.files = const [],
    this.error,
  });

  bool get isBusy =>
      phase == A7Phase.scanning ||
      phase == A7Phase.connecting ||
      phase == A7Phase.binding;

  A7State copyWith({
    A7Phase? phase,
    List<A7Scan>? found,
    A7Scan? device,
    DeviceInfo? info,
    List<FileEntry>? files,
    String? error,
    bool clearError = false,
  }) =>
      A7State(
        phase: phase ?? this.phase,
        found: found ?? this.found,
        device: device ?? this.device,
        info: info ?? this.info,
        files: files ?? this.files,
        error: clearError ? null : (error ?? this.error),
      );
}
