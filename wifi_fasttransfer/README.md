> # ⚠️ 已作废(2026-06-29 真机 HCI 推翻)
> 这里 `E5 5E / e606` 的结论是 blutter 静态误判。**真协议 = 旧 `A0 0A` 通道(b0b1) + 新命令 `0x1B`**,
> 开热点帧 `A0 0A 01 1B 01 01 <CRC>`(回 `…1B 01 00` 成功);以飞书手册第 13 节为准。
> Phase 2 已按真协议实装(`app/a7_protocol` + App `lib/wifi/` + `wifi_transfer_screen.dart`);联调用 `web/keep_wifi.py`。

---

# (作废)Wi-Fi 快传 · 阶段 1 逆向 spike(产物)

新机 A7(X95-AINOTE / 广播名「AI Note」/ SN 前缀 Q95)Soft AP Wi-Fi 快传协议的逆向结论与验证脚本。

## 文件
- **`PROTOCOL.md`** —— 协议结论(**核心更正:不是 protobuf,是现有 A0 帧换头 `E5 5E` + 新命令 id**)+ 帧格式 + 命令表 + e606 通道 + HTTP API。
- **`verify_wifi.py`** —— 独立验证脚本:BLE 连 → 绑定 → e606 开热点 → 连 `Doway_<SN>` → `GET /get_files`。

## 已自检(本机,无需硬件)
```
$ python3 verify_wifi.py --selftest
OpenWifi(open) : E5 5E 01 1B 01 01 0E 53      ← 开热点整帧,直接写 E606E15E
HeartWifi      : E5 5E 01 35 00 18 AE
CloseWifi      : E5 5E 01 21 00 17 AE
Bind(183396)   : A0 0A 01 03 11 31 38 33 33 39 36 00…00 2E 6E
CRC '123456789' -> 0xBB3D OK                  ← CRC-16/ARC 实现正确
```

## 怎么重跑 blutter(复现逆向)
```bash
brew install cmake ninja pkg-config icu4c capstone
pip3 install pyelftools requests
git clone https://github.com/worawit/blutter /tmp/blutter
export PKG_CONFIG_PATH="$(brew --prefix icu4c)/lib/pkgconfig"
python3 /tmp/blutter/blutter.py doway_apk/x/arm/lib/arm64-v8a /tmp/blutter_out
# 关键文件:
#   asm/.../cmd_3085s/request_3085s.dart      —— BleRequest3085s.pack()=分帧(E5 5E / A0 0A + CRC)
#   asm/.../cmd_3085s/setting/wifi.dart        —— OpenWifi/HeartWifi/... 负载(createValue/unpack)
#   asm/.../cmd_3085s/key_profiles.dart        —— 命令 id(openWifi=27 等)
```
环境:Dart 3.7.2 / Flutter ~3.29,libapp.so 33M,反编译耗时 ~7 分钟。

## 真机验证(这是 Eddie 要的「确定可以连」,需新机硬件)
```bash
pip install bleak requests
python3 verify_wifi.py --name "AI Note"     # 连新机 → 绑定 → 开热点
# 脚本提示后,系统 Wi-Fi 连 'Doway_<SN>' → 回车 → 自动 GET /get_files
# 或已在热点上:python3 verify_wifi.py --http-only
```
**阶段 1 通过的两条证据**(真机产出):
1. 设备开出 `Doway_<SN>` 热点(发 `E5 5E 01 1B 01 01 0E 53` 到 `E606E15E` 后)。
2. `GET http://192.168.200.1/get_files` 返回真实文件清单 JSON。

## 静态没法 100% 定死、留真机/HCI 钉死的点
见 `PROTOCOL.md` 第 6 节(绑定走哪个通道、`deviceToAppWifiInfo` 两段 UTF 含义、`field_2b` 触发、CRC 是否含头)。
替代证据路:非荣耀安卓机抓一次官方 App 开 Wi-Fi 的 HCI(btsnoop),比对 `E5 5E 01 1B 01 01 …` 一帧即全部钉死。
