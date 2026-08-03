# 本地快传传输规格(真协议)—— blutter 反编译自 `wif_mgr.dart`

来源:`DoWayWifiMgr`(`asm/doway/dowayProtocol/wifi/wif_mgr.dart`)。**这是设备本地 AP 传输的真协议**,
取代之前 `wifi_http_client.dart` 里「HTTP `GET /get_files`」的错误假设。

## 直接回答 6 个问题

**1. 传输方式 = 裸 TCP `Socket`(不是 HTTP)。**
`DoWayWifiMgr.startSocket()` → `[dart:io] Socket.connect("192.168.200.1", 8475, timeout:…)`(addr `0x193a3e8`)。
没有 `HttpClient`、没有 URL。`get_files`/`get_file_info` 那套是 `cloud_*` 前缀的**云端**接口(dowayai.com),与本地无关。

**2. 端口 = `8475`(0x211B)。**
`mov x2, #0x211b` 紧挨 `Socket.connect`(addr `0x193a3dc`)。带 3 次重试、每次间隔 2s(retry 闭包 "尝试第 N 次连接…")。

**3. 请求/响应 = 自定义二进制帧,magic 头尾定界(不是 A0/CRC 的 BLE 帧)。**
`DoWayWifiMgr.write(msg)`(addr `0x1433958`)拼帧后 `writeBytes` → `socket.add(bytes)`:
```
"XnoteWifiHead  "   15B  魔术头(ASCII,"XnoteWifiHead"+2空格)
cmdId               1B   命令 id(见下表;writeByte)
short(0x0000)       2B   保留 0(writeShort)
short(0x0000)       2B   保留 0(writeShort)
payloadLen          4B   payload 字节数(writeInt)
payload             N B  命令负载(各命令的 createValue)
"XnoteWifiTail   "  16B  魔术尾(ASCII,"XnoteWifiTail"+3空格)
```
收方向(`onData`,addr `0x193aa34`)把 socket 字节攒进缓冲,按 `indexOf("XnoteWifiHead")` / `"XnoteWifiTail"`
切出整帧再解(`sublist`)。

**命令 id(`SettingKey3085s`)**:`getFiles=10` · `startSyncFile=11` · `endSyncFile=12`(注:这是 cmd_3085s 命名空间,和 BLE 的 0x0a/0x1B 不是同一张表)。

**各命令负载(createValue / unpack,来自 `file.dart`)**:
| 命令 | id | 方向 | payload |
|---|---|---|---|
| getFiles | 10 | 手机→设备 | 空(列清单请求) |
| GetFilesResponse | 10 | 设备→手机 | 每条:`name(UTF)` + `size(int,4B)` + `type(byte)`(可能多条/多帧) |
| startSyncFile | 11 | 手机→设备 | `fileName(UTF)` + `offset(int,4B)`(下载某文件;offset 一般 0) |
| SyncFileResponse | 11 | 设备→手机 | `seq/status(byte)` + `len(int,4B)` + 文件块字节 |
| endSyncFile | 12 | 双向 | 同步结束 |

> UTF 串 = `writeUTFBytes`(2B 长度前缀 + bytes,讯飞同款);`writeInt`/`readInt` = 4B;
> 长度/short 端序走 `ByteData` 的 `Endian` 实例(与 BLE `writeShort` 同),**首次真机抓一帧核 big/little**。

**4. 触发时序 = 必须先 BLE 选文件 + 开热点,设备才开 8475。**
官方 BLE 序列(HCI):`0x03 绑定 → 0x05 → 0x18 → 0x0a 文件列表 → 0x0b 选中文件(回大小)→ 0x1B 开热点 → (文件走 Wi-Fi) → 0x0c`。
**设备的 8475 端口只在 `0x1B` 开热点后才起**(所以早前端口扫描全关 —— 既没扫 8475、也扫得太早)。`startSocket` 的 3 次重试就是等端口起来。

**5. 文件清单两边都有:** BLE `0x0a` 给 UI 列清单;**Wi-Fi 侧也有 `getFiles(10)`**(连上 socket 后先发它列清单,再 `startSyncFile(11)` 下载)。最稳:连上 socket 后用 Wi-Fi 的 getFiles 拿清单。

**6. 本地 vs 云端:** `cloud_get_files`/`cloud_get_file_info`/`cloud_get_files_count` = 云同步(dowayai.com),**不是本地**;本地 AP 就走上面 TCP:8475 + Xnote 帧。

## App 实装(本仓库)
- `lib/wifi/wifi_socket_client.dart` —— 按本规格的 socket 客户端(替代 `wifi_http_client.dart`)。
- BLE 那层(开热点/SSID/密码/序列)不动,已验通。

## ✅ 真机端到端验通(2026-06-29)+ 字段定死
完整下载一条录音 87560B → 拼回 Opus → 解码 19.9s 真音频。早前"待核"项逐条定死:
- **全大端 BE**:帧 `len`、文件 `size`、`startSyncFile` 的 `offset` 都是 BE。
- **head 恒 15B**("XnoteWifiHead"+2 空格):cmd 在第 15 字节、len 在第 20~23 字节;收方向 `indexOf("XnoteWifiHead")` 定位。⚠️ getFiles 首帧 cmd=`0x20`(会话 ack,len=1/payload=00)——那 0x20 是命令字节不是第 3 个空格,别把 head 当 16B。
- **getFiles 请求** = 空 payload(不带 path)。
- **getFiles 响应**每条 = `status(1)=00 + name(14 定长) + size(4 BE) + type(1)`(同 BLE 0x0a);**结束帧 status=02**。
- **startSyncFile 请求** payload = `name(原始 14B ASCII,无长度前缀) + offset(4 BE)`;**响应首帧** = `status(1)+size(4 BE)`,**之后 cmd=11 数据帧** payload = 文件原始字节块(~4040B/块)累加到 size;收完发 `endSyncFile(12)`。
- 下载得到的就是 **Opus 88B 记录流**(`[0:4]BE 80 + [4:8]序号 + [8:88] 80B Opus 包`),直接 libopus 解码。
- 8475 在 `0x1B` openWifi 后即起,**不强依赖**先 0x0b 选文件(空列表也连得上)。
- 联调脚本:`web/softap_download.py`(端到端)。`wifi_socket_client.dart` 已按以上全部收紧。
