"""A7 录音笔 BLE 客户端 — 协议核心 + Mac 传输适配 + CLI。

逆向自《AI 录音笔 BLE 协议 实测修正版 v1》。协议核心(crc/framing/advert/commands)
保持纯逻辑、零蓝牙依赖,可离线单测,并按 1:1 映射到 Android(Kotlin)。
"""

__version__ = "0.0.1"
