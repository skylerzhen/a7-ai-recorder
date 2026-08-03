> # ⚠️ 已作废 —— 真机 HCI 推翻(2026-06-29)
> 本文件早前基于 blutter **静态**分析,得出「换帧头 `E5 5E`、走 e606、写 `E606E15E`」——**真机抓包证明错了**。
> **真协议**:Wi-Fi 快传走**旧 `A0 0A` 通道(b0b1 写 / b0b2 收)**,只多一条命令 **`0x1B` openWifi**:
> 开热点整帧 `A0 0A 01 1B 01 01 <CRC>`,设备回 `A0 0A 01 1B 01 00`(00=成功)。
> SSID = `Doway_`+SN 后 4 位;密码 = SN 前 8 位;网关 `192.168.200.1`。**以飞书手册第 13 节为准。**
> 实装见 `app/a7_protocol`(`openWifi()` / `decodeWifiInfo` / `wifiApFromSn`)+ App `lib/wifi/` + `lib/ui/wifi_transfer_screen.dart`;现场联调用 `web/keep_wifi.py`。
> 下面 `E5 5E` 的内容仅作逆向过程留档,**勿照做**。

---

# (作废)A7 新机(X95-AINOTE)Wi-Fi 快传协议 —— blutter 静态推断(阶段 1)

来源:blutter 反编译 `doway_apk/x/arm/lib/arm64-v8a/libapp.so`(官方 App「Doway」`com.doway.record`,**Flutter / Dart 3.7.2**,快照 `d91c0e6f35f0eb2e44124e8f42aa44a7`)。
逆向产物在 `/tmp/blutter_out/asm/...`(可重跑,见 `README.md`)。

---

## ⚠️ 最重要的一条更正:它**不是** protobuf

飞书手册第 13 节假设「Wi-Fi 快传 = 一套独立的 protobuf 协议」。**反编译证明这是错的。**

实际是:**和现有 A7 的 `A0 0A` 命令协议同一套二进制分帧**(`ByteArray` 手写打包 + CRC-16/ARC),只是
**换了个帧头 `E5 5E`、走 e606 通道、加了几条新命令 id**。没有 protobuf、没有 BleRequest 包裹消息、没有字段 tag。

证据:`OpenWifiRequest extends BleRequest3085s`,而 `BleRequest3085s.pack()`(addr `0x1b3b7d0`)逐字节就是现有
`app/a7_protocol/lib/src/framing.dart` 的 `buildFrame`:写头 → `0x01` → cmd → len → payload → CRC-16/ARC(LE)。
区别只有头两字节:`field_2b` 标志决定写 **`E5 5E`**(addr `0x1b3b85c`:`writeByte(0xE5); writeByte(0x5E)`)还是
`A0 0A`(addr `0x1b3b878`)。CRC 多项式 `0x8005`(addr `0x1b3b918`)= 现有 CRC-16/ARC(reflected `0xA001`)。

**结论:Phase 2 直接复用现有 `buildFrame`,把帧头从 `[0xA0,0x0A]` 换成 `[0xE5,0x5E]` 即可,不需要 protobuf 库。**

---

## 1. 帧格式(e606 Wi-Fi 命令)

```
┌────┬────┬──────┬─────┬─────┬──────────────┬───────────────┐
│E5  │5E  │ 0x01 │ CMD │ LEN │ PAYLOAD[LEN] │ CRC16 (2B LE) │
└────┴────┴──────┴─────┴─────┴──────────────┴───────────────┘
  帧头(e606)  版本   命令id  长度    负载            CRC-16/ARC
```
- **帧头** `E5 5E`(走 e606 时);`A0 0A` 是旧通道(B0B0)。往 e606 发 `A0 0A` 帧会被设备断连。
- **版本** 恒 `0x01`。
- **CMD** 1 字节命令 id(见下表)。
- **LEN** 1 字节负载长度(0–255)。
- **PAYLOAD** LEN 字节(命令各自定义)。
- **CRC** CRC-16/ARC(poly reflected `0xA001`,init 0,refin/refout),**校验范围 = 帧头..负载(含 `E5 5E`)**,小端追加。
  —— 与现有 `app/a7_protocol/lib/src/crc.dart` + `framing.dart` 完全一致。

## 2. BLE 通道(e606)

| 用途 | UUID |
|---|---|
| 服务 | `E606E15D-DA3D-6F45-5978-A7A5B8CEA2C0` |
| **写**(发命令) | `E606E15E-DA3D-6F45-5978-A7A5B8CEA2C0` |
| **通知**(收响应) | `E606E15F-DA3D-6F45-5978-A7A5B8CEA2C0` |

旧通道(绑定/设备信息等仍用):服务 `0000b0b0…`、写 `0000b0b1…`、命令通知 `0000b0b2…`。

## 3. Wi-Fi 命令表(`SettingKey3085s`,来自 `key_profiles.dart`)

| 命令 | id(dec / hex) | 方向 | 负载 / 解析 |
|---|---|---|---|
| **openWifi** `OpenWifiRequest` | 27 / `0x1B` | 手机→设备 | **1 字节**:`0x01`=开热点 / `0x00`=关(`createValue` addr `0x1c62f28`:`writeByte(bool?1:0)`) |
| **closeWifi** `CloseWifiRequest` | 33 / `0x21` | 手机→设备 | 空负载(标注「关闭 wifi, 通过 wifi 发送」) |
| **wifiHeart** `HeartWifiRequest` | 53 / `0x35` | 手机→设备 | **空负载**(保活心跳;`createValue` addr `0x1c62fa4` 不写任何字节) |
| **wifiSocket** `WifiSocketResponse` | 32 / `0x20` | 设备→手机 | socket 状态(响应) |
| **deviceToAppWifiInfo** `WifiInfoReportResponse` | 31 / `0x1F` | 设备→手机 | **2 个定长 UTF 串**:`readUTFBytes(10)` + `readUTFBytes(8)`(`unpack` addr `0x1aba404`)→ 疑为 SSID 后缀 / 口令,**待 HCI 确认含义** |
| heartWifi 响应 `HeartWifiResponse` | — | 设备→手机 | 1 字节状态(`readByte`) |
| openWifi 响应 `OpenWifiResponse` | — | 设备→手机 | 1 字节状态 |

> **开热点 = `OpenWifiRequest(open=true)`**,整帧:`E5 5E 01 1B 01 01 <CRC16-LE>`(CRC 由脚本计算)。

## 4. 开热点后的 HTTP(设备↔手机本地直连)

- 设备开 Soft AP:**SSID `Doway_<SN>`**,网关 **`192.168.200.1`**(无外网)。
- 手机连该热点后,打 `http://192.168.200.1`:
  - `GET /get_files`、`GET /get_file_info`、`GET /get_files_count`
  - `POST /add_file`、`/delete_file`、`/batch_move_file`、`/batch_recycle_file`
  - `GET /doway_download/...`、`/ota/...`(OTA,本轮不碰)
- 保活:`HeartWifiRequest`(id 53)周期心跳;关闭:`CloseWifiRequest`(id 33)。

## 5. 绑定(快传前置)

沿用旧机:cmd **`0x03`** bind,负载 = 16 字节配对码(`183396` 右侧补 0)+ 1 字节 op(`0x00`=绑定)。
**待真机确认**:绑定是走旧通道(`A0 0A`→`0000b0b1`)还是 e606(`E5 5E`→`E606E15E`)。脚本默认先走旧通道。

## 6. 还需真机/HCI 落实的点(本轮静态没法 100% 定死)

1. `field_2b` 触发 `E5 5E` 的确切条件(连上新机后是否对所有 e606 写都用 `E5 5E`)。
2. `deviceToAppWifiInfo`(id 31)两段 UTF(10B/8B)的确切含义(SSID? 口令? 是否就是连热点要的密码)。
3. 绑定走哪个通道。
4. CRC 是否真覆盖帧头 `E5 5E`(静态看 `getWriteBytes()` 含头,与旧帧一致;以 HCI 抓一帧核对最稳)。

> 这些都可由「一次官方 App 开 Wi-Fi 的 HCI 抓包(非荣耀安卓机)」一次性钉死;脚本 `verify_wifi.py` 跑通 `/get_files` 也能反证主链路成立。
