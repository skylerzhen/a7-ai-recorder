import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

/// 申请 BLE 运行时权限。
/// Android 12+:bluetoothScan + bluetoothConnect(manifest 已声明 neverForLocation,无需定位)。
/// 旧机型(<=11):扫描需要定位,这里一并尝试 location。
/// 返回是否拿到「扫描+连接」所需权限,以及给用户看的提示。
Future<({bool granted, String? message})> ensureBlePermissions() async {
  // iOS 没有 Android 的 bluetoothScan/Connect 运行时权限(那是 Android 12 专属);
  // CoreBluetooth 会在首次 startScan 时按 Info.plist 的 NSBluetoothAlwaysUsageDescription
  // 自动弹原生授权框。这里直接放行,交给 FlutterBluePlus.startScan 触发系统弹框。
  if (Platform.isIOS) {
    return (granted: true, message: null);
  }

  // Android 12+:只申请 scan + connect(manifest 已声明 neverForLocation,不要定位)。
  // 旧机型(<=11)扫描还需 ACCESS_FINE_LOCATION 运行时授权;本期目标机为 12+,
  // 兼容旧机可加 device_info_plus 按 SDK 分支补 location(报告已注明)。
  final results = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
  ].request();

  // 低版本上 bluetoothScan/Connect 不存在,permission_handler 返回 granted。
  final scan = results[Permission.bluetoothScan] ?? PermissionStatus.granted;
  final conn = results[Permission.bluetoothConnect] ?? PermissionStatus.granted;

  if (scan.isGranted && conn.isGranted) {
    return (granted: true, message: null);
  }
  final permanent = scan.isPermanentlyDenied || conn.isPermanentlyDenied;
  return (
    granted: false,
    message: permanent
        ? '蓝牙权限被永久拒绝。请到 系统设置 → 应用 → 权限 → 附近的设备 手动开启后重试。'
        : '需要「附近的设备/蓝牙」权限才能扫描 A7,请允许后再点扫描。',
  );
}
