"""Soft AP 逆向 step5(收尾尝试):
1) 查绑定信息 0x02  2) 试绑定 0x03(旧机默认码 183396)  3) 再查 0x02
4) 宽扫 B0B0 0x21-0x4f 找含 SSID 的回包
5) 最后测 c0c1 是否还断连(绑定后是否解锁)
"""
from __future__ import annotations

import asyncio
import re
import sys

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import transport as T
from a7ble.framing import build_frame, parse_frame
from a7ble import commands as C
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"


async def find_device(timeout=25.0):
    fut = asyncio.get_event_loop().create_future()
    def cb(d, ad):
        if fut.done(): return
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if adv and adv.sn.startswith(TARGET_SN): fut.set_result(d)
    sc = BleakScanner(detection_callback=cb)
    await sc.start()
    try: return await asyncio.wait_for(fut, timeout)
    finally: await sc.stop()


def pr(b): return "".join(chr(x) if 32<=x<127 else "." for x in b)


async def main():
    print(f"扫蓝牙,请让新设备({TARGET_SN})醒着、手机别连它...")
    try: device = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到。"); return
    print(f"找到 {device.name},连接...\n")

    def mk(nm):
        def _cb(_s, data):
            asc = pr(bytes(data))
            flag = "  <<< 可读串!" if re.search(r"[A-Za-z]{4,}", asc) else ""
            f = parse_frame(bytes(data))
            tag = f"0x{f.cmd:02x}" if f.crc_ok else "raw"
            print(f"     <RX {nm} {tag}> {bytes(data).hex(' ')} \"{asc}\"{flag}")
        return _cb

    async with BleakClient(device) as client:
        m = {}
        for svc in client.services:
            for ch in svc.characteristics:
                m[ch.uuid.split('-')[0][-4:]] = ch
        for nm in ("b0b2","c0c2","e15f"):
            if nm in m:
                try: await client.start_notify(m[nm], mk(nm))
                except Exception: pass

        async def wb0(frame, label):
            if not client.is_connected:
                print(f"   [断开,跳过 {label}]"); return
            print(f">>> {label}: {frame.hex(' ')}")
            try: await client.write_gatt_char(m["b0b1"], frame, response=False)
            except Exception as e: print(f"   写失败: {e}")
            await asyncio.sleep(1.2)

        await wb0(C.get_bind_info(), "0x02 查绑定信息")
        await wb0(C.bind("183396".encode(), 0x00), "0x03 绑定(码=183396)")
        await wb0(C.get_bind_info(), "0x02 再查绑定")

        print("\n>>> 宽扫 B0B0 0x21-0x4f(找含 SSID 的回包)...")
        for cmd in range(0x21, 0x50):
            if not client.is_connected:
                print(f"   [断于 0x{cmd:02x} 前]"); break
            try: await client.write_gatt_char(m["b0b1"], build_frame(cmd), response=False)
            except Exception: pass
            await asyncio.sleep(0.5)

        print(f"\n>>> 测 c0c1 是否解锁(绑定后还断不断)... connected={client.is_connected}")
        if client.is_connected and "c0c1" in m:
            try:
                await client.write_gatt_char(m["c0c1"], build_frame(0x05), response=False)
                await asyncio.sleep(1.5)
                print(f"    写 c0c1 后 connected={client.is_connected}  "
                      f"{'→ 仍断,绑定未解锁' if not client.is_connected else '→ 没断!绑定可能解锁了,值得深挖'}")
            except Exception as e:
                print(f"    c0c1 写失败: {e}")
        await asyncio.sleep(1.0)

    print("\n=== 完 ===")


if __name__ == "__main__":
    asyncio.run(main())
