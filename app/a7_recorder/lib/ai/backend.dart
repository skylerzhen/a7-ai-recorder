import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 生产后端默认地址(走 Cloudflare → 服务器 nginx → 容器 127.0.0.1:8787)。
/// ⚠️ 占位:eddie 定好域名后改这一行常量即可;设置页可临时覆盖(本地/局域网调试,
/// 如模拟器 `http://10.0.2.2:8787`、真机 `http://[Mac局域网IP]:8787`)。
/// http 用于 /process、/health;ws 用于 /stream(由 [wsStreamUrl] 派生)。
const String kBackendBaseDefault = 'https://a7.coolai.tech'; // TODO(eddie): 换成正式域名

final backendBaseProvider = StateProvider<String>((ref) => kBackendBaseDefault);

String wsStreamUrl(String httpBase) {
  var u = httpBase.trim().replaceAll(RegExp(r'/$'), '');
  u = u.replaceFirst('http://', 'ws://').replaceFirst('https://', 'wss://');
  return '$u/stream';
}
