import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../device/a7_device.dart';
import '../library/recording_store.dart';
import '../wifi/wifi_connector.dart';
import '../wifi/wifi_socket_client.dart';
import 'theme.dart';

/// Wi-Fi 快传(仅新机 X95-AINOTE):
/// 0x1B 开热点 → 取 SSID/密码 → 连 `Doway_<SN>` 热点 → HTTP 列清单 → 勾选下载入库。
/// 期间周期发 0x05 保活 BLE(BLE 断热点关);退出时断热点、恢复原网络。失败回退 BLE 取文件。
class WifiTransferScreen extends ConsumerStatefulWidget {
  const WifiTransferScreen({super.key});

  @override
  ConsumerState<WifiTransferScreen> createState() => _WifiTransferScreenState();
}

enum _Phase { preparing, pick, downloading, done, error }

class _WifiTransferScreenState extends ConsumerState<WifiTransferScreen> {
  _Phase _phase = _Phase.preparing;
  String _status = '正在开启设备热点…';
  String? _error;
  String _ssid = '';

  List<WifiFile> _files = const [];
  final Set<String> _selected = {};
  WifiSocketClient? _sock;
  Timer? _keepAlive;

  // 下载进度
  int _doneCount = 0;
  String _curName = '';
  int _curReceived = 0;
  int _curTotal = 0;
  int _imported = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _keepAlive?.cancel();
    _sock?.close();
    WifiConnector.disconnect(); // 解绑进程网络、恢复原 Wi-Fi
    super.dispose();
  }

  Future<void> _prepare() async {
    final dev = ref.read(a7Provider.notifier);
    try {
      _set('正在开启设备热点…');
      final ok = await dev.startWifiAp();
      if (!ok) throw Exception('设备未接受开热点命令(0x1B 回包非成功)');

      _set('读取热点信息…');
      final ap = await dev.fetchWifiInfo();
      _ssid = ap.ssid;

      // BLE 保活:连热点/传文件期间周期发 0x05,BLE 断则设备关热点
      _keepAlive?.cancel();
      _keepAlive = Timer.periodic(const Duration(seconds: 5), (_) {
        dev.refreshInfo().catchError((_) {});
      });

      _set('连接热点 ${ap.ssid} …');
      final connected = await WifiConnector.connect(ap.ssid, ap.password);
      if (!connected) throw Exception('连接热点失败');

      _set('连接传输端口(8475)…');
      final sock = WifiSocketClient();
      _sock = sock;
      await sock.connect(); // 设备开热点后才起,内部重试
      _set('读取卡上录音清单…');
      final files = await sock.listFiles();
      if (!mounted) return;
      setState(() {
        _files = files;
        _phase = _Phase.pick;
        _status = '共 ${files.length} 个文件';
      });
    } catch (e) {
      _keepAlive?.cancel();
      if (mounted) {
        setState(() {
          _phase = _Phase.error;
          _error = '$e';
        });
      }
    }
  }

  void _set(String s) {
    if (mounted) {
      setState(() => _status = s);
    }
  }

  bool _alreadyImported(String name) {
    // 轻量去重(沿用"已入库即跳过"):按标题匹配已有录音
    final recs = ref.read(recordingStoreProvider);
    return recs.any((r) => r.title == name);
  }

  Future<void> _downloadSelected() async {
    final store = ref.read(recordingStoreProvider.notifier);
    final names = _selected.toList();
    setState(() {
      _phase = _Phase.downloading;
      _doneCount = 0;
      _imported = 0;
    });
    for (final name in names) {
      if (_alreadyImported(name)) {
        setState(() => _doneCount++);
        continue;
      }
      setState(() {
        _curName = name;
        _curReceived = 0;
        _curTotal = 0;
      });
      try {
        final file = _files.firstWhere((f) => f.name == name,
            orElse: () => const WifiFile(name: '', size: 0));
        final bytes = await _sock!.download(name, file.size, onProgress: (r, t) {
          if (mounted) {
            setState(() {
              _curReceived = r;
              _curTotal = t;
            });
          }
        });
        // 新机文件是 Opus(88B 记录流);存 .opus。直接播放需 Opus 解码管线(另一棒改造)。
        final saveName = name.contains('.') ? name : '$name.opus';
        await store.addDownloaded(name: saveName, bytes: bytes);
        if (mounted) setState(() => _imported++);
      } catch (e) {
        // 单个失败不中断整批;记进 error 文案
        _error = '${_error ?? ''}\n$name 下载失败:$e';
      }
      if (mounted) setState(() => _doneCount++);
    }
    if (mounted) setState(() => _phase = _Phase.done);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wi-Fi 快传')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.m),
          child: switch (_phase) {
            _Phase.preparing => _preparing(),
            _Phase.pick => _pick(),
            _Phase.downloading => _downloading(),
            _Phase.done => _doneView(),
            _Phase.error => _errorView(),
          },
        ),
      ),
    );
  }

  Widget _preparing() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: AppSpacing.l),
            Text(_status, style: AppText.body, textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.s),
            Text('热点无外网,系统可能弹框让你确认连接 Doway_…', style: AppText.faint, textAlign: TextAlign.center),
          ],
        ),
      );

  Widget _pick() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('热点 $_ssid · ${_files.length} 个文件', style: AppText.caption),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                if (_selected.length == _files.length) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(_files.map((f) => f.name));
                }
              }),
              child: Text(_selected.length == _files.length ? '取消全选' : '全选'),
            ),
          ],
        ),
        Expanded(
          child: _files.isEmpty
              ? Center(child: Text('卡上没有文件', style: AppText.faint))
              : ListView.builder(
                  itemCount: _files.length,
                  itemBuilder: (_, i) {
                    final f = _files[i];
                    final imported = _alreadyImported(f.name);
                    return CheckboxListTile(
                      dense: true,
                      value: _selected.contains(f.name),
                      onChanged: imported ? null : (v) => setState(() {
                        if (v == true) {
                          _selected.add(f.name);
                        } else {
                          _selected.remove(f.name);
                        }
                      }),
                      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(imported ? '已入库' : _fmtSize(f.size), style: AppText.caption),
                    );
                  },
                ),
        ),
        SizedBox(
          height: 50,
          child: FilledButton.icon(
            onPressed: _selected.isEmpty ? null : _downloadSelected,
            icon: const Icon(Icons.download),
            label: Text('下载 ${_selected.length} 个'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.teal, foregroundColor: Colors.white),
          ),
        ),
      ],
    );
  }

  Widget _downloading() {
    final pct = _curTotal > 0 ? _curReceived / _curTotal : null;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('下载中 $_doneCount / ${_selected.length}', style: AppText.body),
          const SizedBox(height: AppSpacing.s),
          Text(_curName, style: AppText.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: AppSpacing.m),
          SizedBox(width: 220, child: LinearProgressIndicator(value: pct)),
          if (_curTotal > 0) ...[
            const SizedBox(height: 4),
            Text('${_fmtSize(_curReceived)} / ${_fmtSize(_curTotal)}', style: AppText.caption),
          ],
        ],
      ),
    );
  }

  Widget _doneView() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: AppColors.ok, size: 48),
            const SizedBox(height: AppSpacing.m),
            Text('完成:入库 $_imported 个', style: AppText.title),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s),
              Text(_error!.trim(), style: AppText.caption.copyWith(color: AppColors.danger),
                  textAlign: TextAlign.center),
            ],
            const SizedBox(height: AppSpacing.l),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回'),
            ),
          ],
        ),
      );

  Widget _errorView() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 44),
            const SizedBox(height: AppSpacing.m),
            Text('Wi-Fi 快传没成功', style: AppText.body.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.l),
              child: Text(_error ?? '', style: AppText.caption, textAlign: TextAlign.center),
            ),
            const SizedBox(height: AppSpacing.l),
            // 回退:返回去用 BLE 取文件(旧路径不受影响)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('返回(改用 BLE 取文件)'),
            ),
          ],
        ),
      );

  static String _fmtSize(int b) {
    if (b <= 0) return '';
    if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(1)} MB';
    if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(0)} KB';
    return '$b B';
  }
}
