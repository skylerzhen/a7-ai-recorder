#!/usr/bin/env python3
"""
A7 新机(X95-AINOTE)Wi-Fi 快传 —— 阶段 1 验证脚本。

链路:BLE 连新机 → 绑定(183396)→ e606 发 OpenWifiRequest(开热点)
      → 设备开出 Doway_<SN> 热点 → 手机/电脑连该热点 → GET http://192.168.200.1/get_files。

协议结论(见 PROTOCOL.md):**不是 protobuf**,就是现有 A0-family 帧,换头 E5 5E + 新命令 id。
帧 = HEAD(E5 5E) | 0x01 | CMD | LEN | PAYLOAD | CRC16-ARC(LE,范围=帧头..负载)。

用法:
  # 1) 不接硬件,先自检帧字节是否正确(本机可跑):
  python3 verify_wifi.py --selftest
  # 2) 接新机真机(需 bleak):扫描→连→绑定→开热点;开出后按提示连热点:
  python3 verify_wifi.py --name "AI Note"          # 或 --address <BLE地址>
  # 3) 已经连上 Doway_ 热点后,只验 HTTP:
  python3 verify_wifi.py --http-only

依赖:pip install bleak requests
"""
import argparse
import asyncio
import sys

# ───────────────────────── 协议(与 app/a7_protocol 完全一致) ─────────────────────────
HEAD_E606 = bytes([0xE5, 0x5E])   # e606 Wi-Fi 通道帧头(新)
HEAD_A0   = bytes([0xA0, 0x0A])   # 旧通道(B0B0)帧头
VERSION   = 0x01

CMD_BIND       = 0x03   # 旧机绑定(配对码 + op)
CMD_OPEN_WIFI  = 0x1B   # 27 openWifi:payload 1B,0x01=开
CMD_CLOSE_WIFI = 0x21   # 33 closeWifi
CMD_WIFI_HEART = 0x35   # 53 wifiHeart:空负载,周期保活
CMD_WIFI_INFO  = 0x1F   # 31 deviceToAppWifiInfo(设备上报,响应)
CMD_WIFI_SOCK  = 0x20   # 32 wifiSocket(响应)

# BLE UUID
SVC_E606    = "e606e15d-da3d-6f45-5978-a7a5b8cea2c0"
CH_E606_TX  = "e606e15e-da3d-6f45-5978-a7a5b8cea2c0"  # 写(发命令)
CH_E606_RX  = "e606e15f-da3d-6f45-5978-a7a5b8cea2c0"  # 通知(收响应)
CH_B0B1_TX  = "0000b0b1-0000-1000-8000-00805f9b34fb"  # 旧:写
CH_B0B2_RX  = "0000b0b2-0000-1000-8000-00805f9b34fb"  # 旧:命令通知

GATEWAY = "http://192.168.200.1"


def crc16_arc(data: bytes) -> int:
    """CRC-16/ARC(reflected 0xA001,init 0)。同 a7_protocol/lib/src/crc.dart。"""
    crc = 0
    for b in data:
        crc ^= (b & 0xFF)
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if (crc & 1) else (crc >> 1)
    return crc & 0xFFFF


def build_frame(cmd: int, data: bytes = b"", head: bytes = HEAD_E606) -> bytes:
    """HEAD | 0x01 | CMD | LEN | DATA | CRC16-LE(范围=帧头..DATA)。"""
    assert 0 <= cmd <= 0xFF and len(data) <= 0xFF
    body = head + bytes([VERSION, cmd & 0xFF, len(data) & 0xFF]) + data
    crc = crc16_arc(body)
    return body + bytes([crc & 0xFF, (crc >> 8) & 0xFF])


def bind_frame(code: str = "183396") -> bytes:
    """0x03 绑定:16B 配对码(右补 0)+ 1B op(0x00=绑定)。默认旧通道头。"""
    payload = code.encode("ascii")[:16].ljust(16, b"\x00") + bytes([0x00])
    return build_frame(CMD_BIND, payload, head=HEAD_A0)


def open_wifi_frame(open_: bool = True) -> bytes:
    return build_frame(CMD_OPEN_WIFI, bytes([0x01 if open_ else 0x00]), head=HEAD_E606)


def heart_frame() -> bytes:
    return build_frame(CMD_WIFI_HEART, b"", head=HEAD_E606)


def _hex(b: bytes) -> str:
    return " ".join(f"{x:02X}" for x in b)


def selftest() -> None:
    print("== 帧自检(无需硬件)==")
    f = open_wifi_frame(True)
    print(f"OpenWifi(open)  : {_hex(f)}")
    print(f"  期望模板       : E5 5E 01 1B 01 01 <CRC_LO CRC_HI>")
    print(f"HeartWifi       : {_hex(heart_frame())}")
    print(f"CloseWifi       : {_hex(build_frame(CMD_CLOSE_WIFI, b'', head=HEAD_E606))}")
    print(f"Bind(183396)    : {_hex(bind_frame())}")
    # CRC 已知向量回归:CRC-16/ARC('123456789') == 0xBB3D
    assert crc16_arc(b"123456789") == 0xBB3D, "CRC-16/ARC 实现错误"
    print("CRC 标准向量 '123456789' -> 0x%04X (期望 0xBB3D) OK" % crc16_arc(b"123456789"))


# ───────────────────────── HTTP(连上 Doway_ 热点后) ─────────────────────────
def http_get_files() -> bool:
    try:
        import requests
    except ImportError:
        print("缺 requests:pip install requests"); return False
    for path in ("/get_files_count", "/get_files"):
        try:
            r = requests.get(GATEWAY + path, timeout=8)
            print(f"GET {path} -> {r.status_code}")
            print(r.text[:4000])
        except Exception as e:
            print(f"GET {path} 失败:{e}(确认已连上 Doway_ 热点、且本机路由指向 192.168.200.1)")
            return False
    return True


# ───────────────────────── BLE(需真机) ─────────────────────────
async def run_ble(args) -> None:
    try:
        from bleak import BleakScanner, BleakClient
    except ImportError:
        print("缺 bleak:pip install bleak"); sys.exit(2)

    # 1) 找设备
    dev = None
    if args.address:
        dev = await BleakScanner.find_device_by_address(args.address, timeout=15)
    else:
        print(f"扫描中(名字含 {args.name!r};新机广播名 'AI Note',SN 前缀 Q95)…")
        dev = await BleakScanner.find_device_by_filter(
            lambda d, ad: (d.name or "").lower().find(args.name.lower()) >= 0, timeout=20)
    if not dev:
        print("没找到设备。按一下机身键唤醒,或用 --address 指定;或 --name 改广播名。"); sys.exit(1)
    print(f"连接 {dev.address} ({dev.name}) …")

    async with BleakClient(dev) as cli:
        print("已连接。发现的特征:")
        for s in cli.services:
            for c in s.characteristics:
                print(f"  {c.uuid}  {c.properties}")

        got = {}

        def on_rx(tag):
            def _cb(_h, data: bytearray):
                print(f"[{tag} 通知] {_hex(bytes(data))}")
                got[tag] = bytes(data)
            return _cb

        # 2) 订阅通知(旧命令回复 + e606 wifi 响应)
        try:
            await cli.start_notify(CH_B0B2_RX, on_rx("b0b2"))
        except Exception as e:
            print(f"(订阅 b0b2 失败,忽略:{e})")
        try:
            await cli.start_notify(CH_E606_RX, on_rx("e606"))
        except Exception as e:
            print(f"!! 订阅 e606 通知失败:{e} —— 新机才有 e606 服务,旧机没有")

        # 3) 绑定(183396)。默认旧通道;若设备要求 e606,把 head 改成 HEAD_E606、写 CH_E606_TX。
        print(f"发绑定帧到 {CH_B0B1_TX}: {_hex(bind_frame(args.code))}")
        try:
            await cli.write_gatt_char(CH_B0B1_TX, bind_frame(args.code), response=False)
        except Exception as e:
            print(f"(绑定写失败,可能新机绑定走 e606:{e})")
        await asyncio.sleep(1.5)

        # 4) e606 发 OpenWifiRequest(开热点)
        frame = open_wifi_frame(True)
        print(f"发开热点帧到 {CH_E606_TX}: {_hex(frame)}")
        await cli.write_gatt_char(CH_E606_TX, frame, response=False)

        # 5) 等设备上报 wifi 信息 / 开出热点,期间发几次心跳保活
        print("等待设备开热点(看上面 e606 通知里的 deviceToAppWifiInfo / OpenWifiResponse)…")
        for _ in range(10):
            await asyncio.sleep(2)
            try:
                await cli.write_gatt_char(CH_E606_TX, heart_frame(), response=False)
            except Exception:
                pass
        print("\n>>> 现在去系统 Wi-Fi 里找并连接 'Doway_<SN>' 热点(无外网),")
        print(">>> 连上后回车,我来 GET http://192.168.200.1/get_files …")
        input()
        http_get_files()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true", help="只验帧字节,不接硬件")
    ap.add_argument("--http-only", action="store_true", help="已连 Doway_ 热点,只验 HTTP")
    ap.add_argument("--name", default="AI Note", help="BLE 广播名关键字")
    ap.add_argument("--address", default="", help="BLE 地址(优先于 --name)")
    ap.add_argument("--code", default="183396", help="绑定配对码")
    args = ap.parse_args()

    if args.selftest:
        selftest(); return
    if args.http_only:
        http_get_files(); return
    asyncio.run(run_ble(args))


if __name__ == "__main__":
    main()
