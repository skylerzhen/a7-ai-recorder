import 'framing.dart';

// --- command ids (reverse-engineered; real-firmware corrected 2026-06-17) ---
// ⚠️ The vendor manual swapped 0x01/0x03. Real firmware: 0x03=bind, 0x01=getSN.
const int cmdGetSn = 0x01; // real: get SN (manual wrongly says 0x03)
const int cmdBindInfo = 0x02;
const int cmdBind = 0x03; // real: bind (manual wrongly says 0x01)
const int cmdSetTime = 0x04;
const int cmdDeviceInfo = 0x05; // returns 52B (manual's "30B" is stale)
const int cmdStartRec = 0x06;
const int cmdStopRec = 0x07;
const int cmdPause = 0x08;
const int cmdResume = 0x09;
const int cmdFileList = 0x0A;
const int cmdGetFile = 0x0B;
const int cmdStopFile = 0x0C;
const int cmdDelete = 0x0D;
const int cmdStatus = 0x0F;
// Wi-Fi 快传(新机 X95-AINOTE,真机 HCI 验通 2026-06-29):走旧 A0 通道(b0b1 写/b0b2 收),非 e606。
const int cmdOpenWifi = 0x1B; // 开/关 Soft AP 热点;payload 1B(0x01=开),回包 cmd 0x1B data[0]==0x00 成功
const int cmdWifiInfo = 0x1F; // 设备推送热点 SSID/密码(发 0x02 后在 b0b2 推 18B)

const int kNameLen = 14;

List<int> _padName(String name) {
  final raw = name.codeUnits; // ASCII names
  if (raw.length > kNameLen) {
    throw ArgumentError('name exceeds $kNameLen bytes: $name');
  }
  return <int>[...raw, ...List.filled(kNameLen - raw.length, 0)];
}

// --- request encoders ---
List<int> getDeviceInfo() => buildFrame(cmdDeviceInfo);

List<int> getSn() => buildFrame(cmdGetSn);

/// 0x02: reply data = bound code, or all-zero if unbound.
List<int> getBindInfo() => buildFrame(cmdBindInfo);

List<int> listFiles() => buildFrame(cmdFileList);

/// seek endianness unverified on real hardware (assumed LE, matches a7ble).
List<int> getFile(String name, {int seek = 0}) {
  final seekBytes = <int>[
    seek & 0xFF,
    (seek >> 8) & 0xFF,
    (seek >> 16) & 0xFF,
    (seek >> 24) & 0xFF,
  ];
  return buildFrame(cmdGetFile, <int>[..._padName(name), ...seekBytes]);
}

List<int> startRecording(String name, int type) =>
    buildFrame(cmdStartRec, <int>[..._padName(name), type & 0xFF]);

List<int> stopRecording() => buildFrame(cmdStopRec);

/// 0x1B openWifi:开/关 Soft AP 热点(Wi-Fi 快传)。payload 1B:0x01=开 / 0x00=关。
/// 走旧 A0 通道(b0b1 写 / b0b2 收),回包 cmd=0x1B 且 data[0]==0x00 即成功。新机(X95-AINOTE)才支持。
/// 整帧示例(开):A0 0A 01 1B 01 01 <CRC16-LE>。
List<int> openWifi({bool open = true}) =>
    buildFrame(cmdOpenWifi, <int>[open ? 0x01 : 0x00]);

List<int> pause() => buildFrame(cmdPause);

List<int> resume() => buildFrame(cmdResume);

/// 0x03 bind: data = 16B pairing code (zero-padded) + op (0x00 bind / 0x01 unbind).
/// Official app uses code "183396". Real firmware: 0x03=bind, 0x01=getSN.
List<int> bind(List<int> code, {int op = 0x00}) {
  if (code.length > 16) {
    throw ArgumentError('bind code exceeds 16 bytes');
  }
  return buildFrame(
    cmdBind,
    <int>[...code, ...List.filled(16 - code.length, 0), op & 0xFF],
  );
}

// --- Wi-Fi 快传:热点参数 ---

/// Soft AP 热点参数。设备在 b0b2 推 0x1F:payload 18B = ssid(10) + password(8)。
/// SSID = `Doway_` + SN 后 4 位;密码 = SN 前 8 位;网关固定 [gateway]。
class WifiApInfo {
  final String ssid;
  final String password;
  const WifiApInfo({required this.ssid, required this.password});

  static const String gateway = 'http://192.168.200.1';

  @override
  String toString() => 'WifiApInfo(ssid: $ssid, password: $password)';
}

String _trimUtf(List<int> bytes) {
  final nul = bytes.indexOf(0);
  return String.fromCharCodes(nul >= 0 ? bytes.sublist(0, nul) : bytes).trim();
}

/// 解 0x1F payload(18B = ssid[0:10] + password[10:18]);短于 18B 时尽力解。
WifiApInfo decodeWifiInfo(List<int> data) {
  final ssid = _trimUtf(data.length >= 10 ? data.sublist(0, 10) : data);
  final password = data.length >= 18
      ? _trimUtf(data.sublist(10, 18))
      : (data.length > 10 ? _trimUtf(data.sublist(10)) : '');
  return WifiApInfo(ssid: ssid, password: password);
}

/// 从 SN 推导热点参数(0x1F 没收到时兜底):SSID=`Doway_`+SN 后 4 位,密码=SN 前 8 位。
/// 例:SN "Q95HA00078" → ssid "Doway_0078" / password "Q95HA000"。
WifiApInfo wifiApFromSn(String sn) {
  final s = sn.trim();
  final last4 = s.length >= 4 ? s.substring(s.length - 4) : s;
  final first8 = s.length >= 8 ? s.substring(0, 8) : s;
  return WifiApInfo(ssid: 'Doway_$last4', password: first8);
}

/// 机型判断:model 含 X95/AINOTE,或 SN 前缀 Q95 → 新机(支持 Wi-Fi 快传)。
bool isWifiCapable({String? model, String? sn}) {
  final m = (model ?? '').toUpperCase();
  final s = (sn ?? '').toUpperCase();
  return m.contains('X95') || m.contains('AINOTE') || s.startsWith('Q95');
}

/// 音频编码分流(M-Opus):新机(X95-AINOTE / SN 前缀 Q95)= `opus`;旧机(X Note / FA9)= `mp3`。
/// **唯一判定函数**,与 [isWifiCapable] 同一套机型判据;实时存盘后缀 / 后端 codec / 本地播放分支都走它。
String audioCodecOf({String? model, String? sn}) =>
    isWifiCapable(model: model, sn: sn) ? 'opus' : 'mp3';

// --- response decoders ---
class FileEntry {
  final String name;
  final int size;
  final int type;
  final List<int> raw;

  const FileEntry({
    required this.name,
    required this.size,
    required this.type,
    required this.raw,
  });
}

/// Entry layout: name(14) + size(4, big-endian) + type(1).
/// The leading 0x0a status byte (0x00/0x01/0x02) is stripped by the caller.
FileEntry decodeFileListEntry(List<int> entry) {
  final nameBytes = entry.sublist(0, kNameLen);
  final nul = nameBytes.indexOf(0);
  final name = String.fromCharCodes(
    nul >= 0 ? nameBytes.sublist(0, nul) : nameBytes,
  );
  final size = (entry[kNameLen] << 24) |
      (entry[kNameLen + 1] << 16) |
      (entry[kNameLen + 2] << 8) |
      entry[kNameLen + 3];
  final type = entry.length > kNameLen + 4 ? entry[kNameLen + 4] : -1;
  return FileEntry(
    name: name,
    size: size,
    type: type,
    raw: List<int>.unmodifiable(entry),
  );
}

class DeviceInfo {
  final int totalMb; // [0:4] big-endian, MB
  final int freeMb; // [4:8] big-endian, MB
  final int charging; // [8] 0 none / 1 charging / 2 full
  final int battery; // [9] 0-100
  final int recording; // [10] 0 idle / 1 recording / 2 paused
  final String version; // [11:14]
  final int usbSupport; // [14]
  final int mode; // [15] 1 normal / 2 call
  final int led; // [16] 0 off / 1 on / 0xFF none
  final String model; // [17:38]
  final int poweroffMin; // [38]
  final int denoise; // [39] 0-16
  final int voiceCtrl; // [40] 0 / 1 / 0xFF none
  final int segment; // [41] 0:30m 1:1h 2:2h 3:3h
  final int backlight; // [42]
  final int usbState; // [43] 0 disconnected / 1 connected
  final List<int> raw;

  const DeviceInfo({
    required this.totalMb,
    required this.freeMb,
    required this.charging,
    required this.battery,
    required this.recording,
    required this.version,
    required this.usbSupport,
    required this.mode,
    required this.led,
    required this.model,
    required this.poweroffMin,
    required this.denoise,
    required this.voiceCtrl,
    required this.segment,
    required this.backlight,
    required this.usbState,
    required this.raw,
  });
}

/// Decode 0x05 device info (52B, capacity big-endian). Verified on A7 "X Note".
DeviceInfo decodeDeviceInfo(List<int> data) {
  int g(int i) => i < data.length ? data[i] : 0;
  int be(int a, int b) {
    if (data.length < b) return 0;
    int v = 0;
    for (int i = a; i < b; i++) {
      v = (v << 8) | data[i];
    }
    return v;
  }

  String strField(int a, int b) {
    final end = b > data.length ? data.length : b;
    final slice = a < end ? data.sublist(a, end) : <int>[];
    final nul = slice.indexOf(0);
    return String.fromCharCodes(nul >= 0 ? slice.sublist(0, nul) : slice);
  }

  final v = data.length >= 14 ? data.sublist(11, 14) : <int>[];
  final version =
      [for (int i = 0; i < 3; i++) (i < v.length ? v[i] : 0).toString()].join('.');

  return DeviceInfo(
    totalMb: be(0, 4),
    freeMb: be(4, 8),
    charging: g(8),
    battery: g(9),
    recording: g(10),
    version: version,
    usbSupport: g(14),
    mode: g(15),
    led: g(16),
    model: strField(17, 38),
    poweroffMin: g(38),
    denoise: g(39),
    voiceCtrl: g(40),
    segment: g(41),
    backlight: g(42),
    usbState: g(43),
    raw: List<int>.unmodifiable(data),
  );
}

// --- 协议补全(2026-06-18,字节布局对账 web/e2e.py·stop.py·status.py·record10.py)---

/// 0x04 设时间:data = [year-2000, month, day, hour, minute, second]。
/// 实测 e2e.py:130(真机回 data[0]==0x00 成功)。year-2000 钳到单字节非负。
List<int> setTime(DateTime t) {
  final y = (t.year - 2000).clamp(0, 255);
  return buildFrame(
    cmdSetTime,
    <int>[y, t.month, t.day, t.hour, t.minute, t.second],
  );
}

/// 设置类 / 录音控制(0x06/0x08/0x09/0x16/0x17…)回包约定:data[0]==0x00 即成功。
/// 实测 e2e.py 的 succ() 判据。
bool isOkReply(List<int> data) => data.isNotEmpty && data[0] == 0x00;

/// 0x07 停录回包 / 0x15 录音信息 共用布局:
/// status(1) + name(14) + size(4,大端) + [type(1)] + [needSync(1)]。
/// 实测 stop.py:70 / status.py:80 / record10.py:55。缺省 type/needSync = -1。
class RecFileInfo {
  final bool ok;
  final String name;
  final int size;
  final int type; // -1 表示回包未带
  final int needSync; // -1 表示回包未带;0/1=是否需要后续同步落盘
  final List<int> raw;

  const RecFileInfo({
    required this.ok,
    required this.name,
    required this.size,
    required this.type,
    required this.needSync,
    required this.raw,
  });
}

RecFileInfo decodeRecFileInfo(List<int> data) {
  final ok = data.isNotEmpty && data[0] == 0x00;
  String name = '';
  int size = 0, type = -1, needSync = -1;
  if (data.length >= 1 + kNameLen) {
    final nb = data.sublist(1, 1 + kNameLen);
    final nul = nb.indexOf(0);
    name = String.fromCharCodes(nul >= 0 ? nb.sublist(0, nul) : nb);
  }
  if (data.length >= 1 + kNameLen + 4) {
    final o = 1 + kNameLen;
    size = (data[o] << 24) | (data[o + 1] << 16) | (data[o + 2] << 8) | data[o + 3];
  }
  if (data.length >= 1 + kNameLen + 5) type = data[1 + kNameLen + 4];
  if (data.length >= 1 + kNameLen + 6) needSync = data[1 + kNameLen + 5];
  return RecFileInfo(
    ok: ok,
    name: name,
    size: size,
    type: type,
    needSync: needSync,
    raw: List<int>.unmodifiable(data),
  );
}

/// 0x0b 取文件回包:status(1) + size(4,大端)。实测 record10.py:123(gf[1:5] 大端)。
/// 随后文件字节走 B0B4,交 [FileReassembler] 累加到 size。
class GetFileReply {
  final bool ok;
  final int size;
  final List<int> raw;

  const GetFileReply({required this.ok, required this.size, required this.raw});
}

GetFileReply decodeGetFileReply(List<int> data) {
  final ok = data.isNotEmpty && data[0] == 0x00;
  int size = 0;
  if (data.length >= 5) {
    size = (data[1] << 24) | (data[2] << 16) | (data[3] << 8) | data[4];
  }
  return GetFileReply(ok: ok, size: size, raw: List<int>.unmodifiable(data));
}

/// 0x0f 设备主动上报状态(周期推送)。
/// M3-gate 真机(2026-06-18)抓到 3 次主动推送 `00 5c.. / 00 5b.. / 00 5a..`:
/// **byte[1]=电量**(92/91/90 单调下降,与 0x05 电量吻合)已确认;其余字节语义未完全定型,
/// 保留 [payload]/[raw],不臆造。后续抓更多状态变化再细化。
class StatusReport {
  final int event; // data[0];空帧为 -1
  final int battery; // data[1](真机确认=电量);缺省 -1
  final List<int> payload; // data[1:]
  final List<int> raw;

  const StatusReport({
    required this.event,
    required this.battery,
    required this.payload,
    required this.raw,
  });
}

StatusReport decodeStatusReport(List<int> data) {
  return StatusReport(
    event: data.isNotEmpty ? data[0] : -1,
    battery: data.length > 1 ? data[1] : -1,
    payload: data.length > 1
        ? List<int>.unmodifiable(data.sublist(1))
        : const <int>[],
    raw: List<int>.unmodifiable(data),
  );
}
