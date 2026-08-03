# M1 验收报告 — Flutter「AI 录音笔」环境搭建 + 协议核心

> 里程碑:M1(环境 + 协议纯逻辑核心,不含蓝牙/设备/UI/AI)。执行机:eddie 的 macOS(Apple Silicon / arm64,macOS 26.5.1)。

## 1. 版本

| 组件 | 版本 | 位置 |
|---|---|---|
| Flutter | 3.44.2 (stable) | `~/development/flutter` |
| Dart | 3.12.2 (随 Flutter) | 同上 |
| JDK | Temurin 17.0.19+10 | `~/development/jdk-17.0.19+10` |
| Android cmdline-tools | latest (15641748) | `~/Library/Android/sdk/cmdline-tools/latest` |
| platform-tools | 37.0.0 | `~/Library/Android/sdk/platform-tools` |
| platforms | android-34 (rev3) + android-36 (rev2) | `.../platforms` |
| build-tools | 34.0.0 + 36.0.0(构建时自动装) | `.../build-tools` |
| NDK / CMake | 28.2.13676358 / 3.22.1(构建时自动装) | `.../ndk` `.../cmake` |
| emulator | 37.1.4 | `~/Library/Android/sdk/emulator` |
| system image | android-34 google_apis arm64-v8a (rev14) | `.../system-images/...` |

环境变量(PATH / JAVA_HOME / ANDROID_HOME / 国内镜像)写在 `app/devenv.sh`,**未写入 `~/.zshrc`**(见偏差 §4)。

## 2. 测试机

- AVD `a7_test`:Android 14(API 34)、google_apis/arm64-v8a、无头启动(`-no-window -gpu swiftshader_indirect`)。
- 启动状态:`emulator-5554 device`,`sys.boot_completed=1`。

## 3. 交付物状态

| # | 交付物 | 状态 |
|---|---|---|
| 1 | `flutter doctor -v` | Android toolchain ✓;Flutter/Chrome/Network ✓;**Xcode [!]**(iOS,后续里程碑,见 §4) |
| 2 | 工程结构 + pubspec | `app/a7_protocol`(纯 Dart 包,**零** flutter/蓝牙依赖)+ `app/a7_recorder`(app) |
| 3 | `dart test` | **23/23 全绿**(crc4 / framing7 / advert3 / commands9,含 2 条真机向量) |
| 4 | 协议核心 Dart 源码 + 测试 | `app/a7_protocol/lib/` + `app/a7_protocol/test/` |
| 5 | App 跑起来截图 | `app/M1_run_screenshot.png`(见文末) |
| 6 | 本报告 | 本文件 |

工程结构:
```
app/
  devenv.sh                # 工具链环境(source 使用)
  a7_protocol/             # 纯 Dart 协议核心(零 flutter/ble 依赖)
    pubspec.yaml           #   dependencies 为空;dev: test
    lib/a7_protocol.dart   #   barrel
    lib/src/{crc,framing,advert,commands}.dart
    test/{crc,framing,advert,commands}_test.dart   # 23 用例
  a7_recorder/             # Flutter app 壳子
    pubspec.yaml           #   path 依赖 ../a7_protocol
    lib/main.dart          #   首页用协议核心算 CRC 证明集成(无业务/无 BLE)
    android/ (minSdk 见 §4)
  M1_REPORT.md
```

## 4. 与 M1 指引的偏差及原因

1. **全部走国内镜像下载**(关键):该机 GitHub 被墙(`git clone` exit 128)、`brew`/ghcr 卡死、`storage.googleapis.com` 慢。改用:Flutter→`storage.flutter-io.cn`、JDK→清华 Adoptium、Android SDK→`dl.google.com`(通)、Gradle→腾讯镜像、Maven→阿里云、pub→`pub.flutter-io.cn`。**这是为了让构建在该网络环境下能完成,不影响产物正确性。**
2. **`parseFrame` 契约对齐 Python**:坏帧返回 `Frame(crcOk:false, cmd:-1)` 而非 `null`(飞书文档第 11 节的 Dart 版返回 null)。这样 `test_detects_bad_head` 等 23 个用例能 1:1 照翻;`advert.parseFromBleak` 未命中仍返回 `null`(对齐 Python `None`)。
3. **协议层做成独立纯 Dart 包**(非 app 内目录):`a7_protocol/pubspec.yaml` 无任何常规 `dependencies`,从结构上保证"零 flutter/蓝牙依赖"且机器可校验(`grep -r package:flutter a7_protocol/lib` 为空)。
4. **环境变量未写入 `~/.zshrc`**:改 shell 配置被安全策略拦截,改放 `app/devenv.sh`,每条命令 `source`。**后果:新开终端需先 `source app/devenv.sh` 才有 flutter/adb。** 可按需写入 profile(需用户授权)。
5. **`minSdk`**:被(用户/linter)有意改回 `flutter.minSdkVersion`,我遵从未还原。实测 APK 生效 **minSdk = 24**(Flutter 3.44.2 默认;targetSdk/compileSdk = 36)。24 ≥ 23,满足 BLE 要求。若验收要求严格硬编码 23,改 `android/app/build.gradle.kts` 一行即可。
6. **模拟器 `package.xml` 手工补**:手工放置的 SDK 组件中,emulator 未被 avdmanager 识别(缺 `package.xml`),按同 schema 生成后正常建 AVD。

## 5. 踩过的坑

- GitHub `clone` 直接失败(exit 128);`brew install openjdk@17` 卡在 ghcr 不动 → 全面换镜像。
- `sdkmanager` 自带下载器在大包(emulator 379MB / 系统镜像 1.5GB)上反复 `Connection reset`;改为直链 `curl -C -`(断点续传)+ 大文件交用户下载。
- 首次 `flutter build` 期间自动装了 NDK 28 / build-tools 36 / CMake(经镜像顺利)。

## 6. 对 M2(扫描/连接/绑定)的风险提示

- `flutter_blue_plus` 的 `advertisementData.manufacturerData` 形态需确认是 `Map<int,List<int>>`,正好喂给 `parseFromBleak`。
- Android 12+ 运行时权限 `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT`,旧机型 `ACCESS_FINE_LOCATION`。
- 设备无连接会休眠停广播 → 需用户按机身键唤醒;连接后 **5 秒内**必须发 `0x03` 绑定否则被断;连上后 `requestMtu(247)`。
- iOS:当前 Xcode 不完整 + 未装 CocoaPods,iOS 真机/模拟器构建留到后续里程碑再补。

## 附:运行截图

见 `app/M1_run_screenshot.png`(模拟器 `a7_test` 上运行 a7_recorder 首页:显示 "M1 · 环境就绪" 与协议核心算出的 CRC)。
