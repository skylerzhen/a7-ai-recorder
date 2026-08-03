import 'package:flutter/services.dart';

/// 连/断设备无外网热点的 Dart 包装(原生实现见 MainActivity.kt `a7/wifi`)。
///
/// connect 成功 = 已 `bindProcessToNetwork`,之后本进程的 http 都会打到 192.168.200.1。
/// 用完务必 disconnect(解绑、恢复默认网络)。
class WifiConnector {
  static const MethodChannel _ch = MethodChannel('a7/wifi');

  /// 连指定热点;返回是否连上(Android 10+;低版本抛 PlatformException UNSUPPORTED)。
  static Future<bool> connect(String ssid, String password) async {
    final ok = await _ch.invokeMethod<bool>('connect', {
      'ssid': ssid,
      'password': password,
    });
    return ok ?? false;
  }

  /// 断开 + 解绑进程网络,恢复原 Wi-Fi/蜂窝。
  static Future<void> disconnect() async {
    try {
      await _ch.invokeMethod('disconnect');
    } catch (_) {/* 忽略 */}
  }
}
