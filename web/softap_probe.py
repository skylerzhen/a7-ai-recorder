"""Soft AP 逆向 step2:向新通道发无害查询帧,捕获回包找 Wi-Fi/SSID 线索。
只发查询类(0x05/0x01/0x02/0x0f),不发删除/使能类高风险命令。
"""
from __future__ import annotations

import asyncio
import sys
import time

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import transport as T
from a7ble.framing import build_frame, parse_frame
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"

C0C1 = "0000c0c1-0000-1000-8000-00805f9b34fb"
C0C2 = "0000c0c2-0000-1000-8000-00805f9b34fb"
E15E = "e606e15e-da3d-6f45-5978-a7a5b8cea2c0"
E15F = "e606e15f-da3d-6f45-5978-a7a5b8cea2c0"


async def find_device(timeout=25.0):
    fut = asyncio.get_event_loop().create_future()
    def cb(device, ad):
        if fut.done(): return
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if adv and adv.sn.startswith(TARGET_SN):
            fut.set_result(device)
    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    try:
        return await asyncio.wait_for(fut, timeout)
    finally:
        await scanner.stop()


def pr(b): return "".join(chr(x) if 32<=x<127 else "." for x in b)


async def main():
    print(f"扫描中,请让新设备({TARGET_SN})醒着、手机别连它...")
    try:
        device = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到目标设备。"); return
    print(f"找到 {device.name},连接...\n")

    pkts = []
    t0 = time.monotonic()
    def mk(name):
        def _cb(_s, data):
            pkts.append((time.monotonic()-t0, name, bytes(data)))
        return _cb

    async with BleakClient(device) as client:
        # 订阅全部 notify
        subs = [("b0b2", T.CHAR_NOTIFY_CMD), ("c0c2", C0C2), ("e15f", E15F)]
        for name, u in subs:
            try:
                await client.start_notify(u, mk(name))
            except Exception as e:
                print(f"[warn] 订阅 {name} 失败: {e}")

        queries = [0x05, 0x01, 0x02, 0x0f]
        # 往两个新写通道分别发查询帧
        for wname, wch in [("c0c1", C0C1), ("e15e", E15E)]:
            for cmd in queries:
                frame = build_frame(cmd)
                print(f">>> 往 {wname} 发 cmd=0x{cmd:02x}: {frame.hex(' ')}")
                try:
                    await client.write_gatt_char(wch, frame, response=False)
                except Exception as e:
                    print(f"    写失败: {e}")
                await asyncio.sleep(1.2)

        await asyncio.sleep(2.0)
        for name, u in subs:
            try: await client.stop_notify(u)
            except Exception: pass

    print(f"\n=== 收到 {len(pkts)} 个回包 ===")
    for t, name, d in pkts:
        f = parse_frame(d)
        tag = f"cmd=0x{f.cmd:02x} crc_ok" if f.crc_ok else "raw"
        print(f"  [{t:6.3f}s] {name}  {d.hex(' ')}  <{tag}>")
        if any(32<=x<127 for x in d):
            print(f'           ascii: "{pr(d)}"')


if __name__ == "__main__":
    asyncio.run(main())
