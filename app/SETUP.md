# A7 录音笔 App — 本地开发说明

> 工具链已装在这台 Mac 上(M1, 2026-06-17)。环境变量集中在 `devenv.sh`,**没有写进 `~/.zshrc`**,所以命令前要么用下面的脚本(已自带 source),要么手动 `source devenv.sh`。

## 一键脚本(推荐)

```bash
cd ~/Desktop/proj/Hospital/app
./emu.sh up         # 启动模拟器(带窗口),等到开机
./emu.sh down       # 关闭模拟器
./emu.sh status     # 看当前设备
./run.sh            # flutter run(热重载;需先 ./emu.sh up)
./test.sh           # 跑协议核心 + app 全部测试
```

## 手动方式

```bash
source ~/Desktop/proj/Hospital/app/devenv.sh   # 之后才有 flutter / dart / adb / sdkmanager
flutter doctor -v
cd a7_protocol && dart test                     # 协议核心 23 单测
cd ../a7_recorder && flutter run
```

## 工具链位置

| 组件 | 路径 |
|---|---|
| Flutter 3.44.2 / Dart 3.12.2 | `~/development/flutter` |
| JDK 17 (Temurin) | `~/development/jdk-17.0.19+10` |
| Android SDK | `~/Library/Android/sdk` |
| AVD | `a7_test`(Android 14 / API 34 / arm64-v8a) |

## 国内镜像(已配好,务必保留)

该机直连 GitHub / Google 多被墙或极慢,以下镜像已写进 `devenv.sh` 和 `a7_recorder/android` 的 gradle 配置:

- Flutter 引擎/Dart SDK → `storage.flutter-io.cn`
- pub 包 → `pub.flutter-io.cn`
- Gradle 发行版 → 腾讯镜像(`mirrors.cloud.tencent.com/gradle`)
- Maven(AGP/AndroidX) → 阿里云(`maven.aliyun.com`)

> 给本机下新 SDK/依赖时优先镜像;大文件(模拟器/系统镜像等)交人工下载更稳。

## 工程结构

```
app/
  devenv.sh                # 工具链环境(脚本自动 source)
  emu.sh / run.sh / test.sh
  a7_protocol/             # 纯 Dart 协议核心(零 flutter/蓝牙依赖,23 单测)
  a7_recorder/             # Flutter app(path 依赖 a7_protocol)
  M1_REPORT.md / M1_*.txt / M1_run_screenshot.png   # M1 验收物
```
