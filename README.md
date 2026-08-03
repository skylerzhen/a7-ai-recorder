# A7 AI Recorder

智芯录音卡片配套的 Flutter AI 录音笔 / 会议副驾原型。项目通过已逆向并经真机验证的私有协议连接录音硬件，覆盖实时音频、BLE/Wi-Fi 文件同步、语音转写、说话人分离、AI 纪要和会中辅助。

> 当前阶段：内部 Alpha / POC。核心技术链路已跑通，但尚未完成商业发布所需的账号鉴权、设备密钥管理、限流、完整后台稳定性和 iOS 真机验收。

## 已支持设备

| 设备 | 识别 | 传输 | 音频 |
|---|---|---|---|
| A7 / X Note | SN 前缀 `FA9` | BLE 控制、B0B3 实时流、B0B4 文件下载 | MP3 32kbps / 16kHz / mono |
| X95-AINOTE / AI Note | SN 前缀 `Q95` | BLE 控制 + SoftAP TCP `192.168.200.1:8475` 快传 | 88B Opus 记录流 |

两类设备均已完成真机协议验证。新机 Wi-Fi 快传协议见 [`wifi_fasttransfer/LOCAL_TRANSFER.md`](wifi_fasttransfer/LOCAL_TRANSFER.md)。

## 产品能力

- Flutter Android App：录音库、设备扫描、设备设置、文件列表、BLE/Wi-Fi 下载、播放和详情页。
- 实时会议：设备音频流、近实时字幕、说话人标签、会中问 AI、主动提示。
- 会后处理：讯飞 LFASR 批量转写、说话人分离、时间戳、豆包纪要。
- 新机 Opus：88B 记录流重封装为 Ogg-Opus，支持本地和实时播放。
- 云端后端：Node/TypeScript，生产地址为 `https://a7.coolai.tech`。

## 目录

```text
a7ble/                  Python/Bleak 协议验证工具
tests/                  Python 协议单测
app/a7_protocol/        纯 Dart 协议核心（零 Flutter/蓝牙依赖）
app/a7_recorder/        Flutter App
app/ai-backend/         Node/TypeScript AI 后端
web/                    真机联调和逆向脚本
wifi_fasttransfer/      新机 Wi-Fi 快传协议文档
```

## 本地开发

```bash
source app/devenv.sh
cd app
./test.sh

cd ai-backend
cp .env.example .env
npm ci
npm test
npm run dev
```

Flutter App：

```bash
source app/devenv.sh
cd app/a7_recorder
flutter analyze
flutter run
```

## 当前验证基线

- `a7_protocol`：62 tests passing
- Flutter App：37 tests passing
- AI backend：37 tests passing
- `flutter analyze`：No issues found
- 生产健康检查：`https://a7.coolai.tech/health`

## 文档

- [BLE 协议开发者手册（飞书）](https://codejoy.feishu.cn/docx/ArQ0dQOqXo1kWqxgryycNwVlnRb)
- [Wi-Fi 本地快传真机协议](wifi_fasttransfer/LOCAL_TRANSFER.md)
- [Wi-Fi 逆向过程文档](wifi_fasttransfer/PROTOCOL.md)

## 安全说明

- 不得提交 `.env`、云端 API Key、生产证书、设备绑定 secret、用户录音或原始抓包。
- 当前服务仍是内测原型；公开或扩大测试范围前，需要增加 API 鉴权、限流和配额。
- 当前 App 中仍存在测试绑定码，量产前必须替换为一机一密的设备身份方案。

