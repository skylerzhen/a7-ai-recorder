"""新硬件(Q95HA00078 / "AI Note")兼容性冒烟测试。

扫到 0x1116 目标设备的瞬间,同一 asyncio 会话立刻连上(绕开"睡眠+按地址重发现"的坑),
然后枚举 GATT、发 0x05 设备信息 / 0x01 取SN / 0x0a 文件列表,逐字段解码对比旧协议。
"""
from __future__ import annotations

import asyncio
import sys
import time

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import commands as C
from a7ble import transport as T
from a7ble.advert import parse_from_bleak
from a7ble.framing import parse_frame

TARGET_SN = "Q95HA00078"


async def find_device(timeout=20.0):
    found = asyncio.get_event_loop().create_future()

    def cb(device, ad):
        if found.done():
            return
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if adv and adv.sn.startswith("Q95HA00078"):
            found.set_result((device, adv))

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    try:
        device, adv = await asyncio.wait_for(found, timeout)
    finally:
        await scanner.stop()
    return device, adv


async def main():
    print(f"扫描中,请按一下新设备({TARGET_SN})唤醒...")
    try:
        device, adv = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到目标设备(没醒/没开机/离太远)。")
        return
    print(f"找到: name={device.name} addr={device.address}")
    print(f"  广播解析: 0x{adv.company_id:04x} MAC={adv.mac} SN={adv.sn}")

    packets = []
    t0 = time.monotonic()

    def make_cb(u):
        def _cb(_s, data):
            packets.append(T.Packet(t=time.monotonic() - t0, char=u, data=bytes(data)))
        return _cb

    print("\n立刻连接(同会话)...")
    async with BleakClient(device) as client:
        print("已连接。枚举 GATT:")
        ctrl_ok = False
        for svc in client.services:
            print(f"  SERVICE {svc.uuid}")
            for ch in svc.characteristics:
                short = ch.uuid.split("-")[0][-4:]
                print(f"    CHAR {short}  [{','.join(ch.properties)}]")
                if svc.uuid == T.SVC_CONTROL:
                    ctrl_ok = True
        print(f"  控制服务 B0B0 存在: {ctrl_ok}")

        for u in T.ALL_NOTIFY:
            try:
                await client.start_notify(u, make_cb(u))
            except Exception as e:
                print(f"  [warn] notify {u[-12:]} 订阅失败: {e}")

        seq = [
            ("0x05 设备信息", C.get_device_info(), 1.5),
            ("0x01 取SN", C.get_sn(), 1.5),
            ("0x0a 文件列表", C.list_files(), 2.5),
        ]
        for label, frame, wait in seq:
            print(f"\n>>> 发送 {label}: {frame.hex(' ')}")
            await client.write_gatt_char(T.CHAR_WRITE, frame, response=False)
            await asyncio.sleep(wait)

        await asyncio.sleep(1.0)
        for u in T.ALL_NOTIFY:
            try:
                await client.stop_notify(u)
            except Exception:
                pass

    print(f"\n=== 收到 {len(packets)} 个 notify 回包 ===")
    for p in packets:
        short = p.char.split("-")[0][-4:]
        f = parse_frame(p.data)
        tag = f"cmd=0x{f.cmd:02x} crc_ok" if f.crc_ok else "raw"
        print(f"  [{p.t:6.3f}s] {short}  {p.data.hex(' ')}  <{tag}>")

    # 解码设备信息
    for p in packets:
        f = parse_frame(p.data)
        if f.crc_ok and f.cmd == C.CMD_DEVICE_INFO:
            di = C.decode_device_info(f.data)
            print(f"\n=== 设备信息解码({di.length if hasattr(di,'length') else len(f.data)}B)===")
            print(f"  型号 model = {di.model!r}")
            print(f"  容量 {di.total_mb}MB / 剩余 {di.free_mb}MB")
            print(f"  电量 {di.battery}%  充电 {di.charging}  录音态 {di.recording}")
            print(f"  固件版本 {di.version}  模式 {di.mode}  降噪 {di.denoise}  声控 {di.voice_ctrl}")
            print(f"  分段 {di.segment}  背光 {di.backlight}  USB {di.usb_support}/{di.usb_state}")
            print(f"  raw = {di.raw.hex(' ')}")


if __name__ == "__main__":
    asyncio.run(main())
