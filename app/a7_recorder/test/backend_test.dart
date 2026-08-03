import 'package:flutter_test/flutter_test.dart';

import 'package:a7_recorder/ai/backend.dart';

// Bug-1:全 App 只有一个后端地址,/stream 由它派生。验 http/https 都正确。
void main() {
  test('http://host:port → ws://host:port/stream(本地/局域网)', () {
    expect(wsStreamUrl('http://10.0.2.2:8787'), 'ws://10.0.2.2:8787/stream');
    expect(wsStreamUrl('http://192.168.45.142:8787'), 'ws://192.168.45.142:8787/stream');
  });

  test('https://域名 → wss://域名/stream(将来部署)', () {
    expect(wsStreamUrl('https://a7.example.com'), 'wss://a7.example.com/stream');
  });

  test('去掉尾部斜杠', () {
    expect(wsStreamUrl('http://host:8787/'), 'ws://host:8787/stream');
  });

  test('生产默认域名是 https → 派生 wss/stream', () {
    expect(kBackendBaseDefault.startsWith('https://'), isTrue);
    final ws = wsStreamUrl(kBackendBaseDefault);
    expect(ws.startsWith('wss://'), isTrue);
    expect(ws.endsWith('/stream'), isTrue);
  });
}
