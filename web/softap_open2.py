"""真机验收 v2:e606 上也绑定 + 订全部通道 + 多触发,定位 openWifi 为何无响应。"""
from __future__ import annotations

import asyncio
import re
import sys

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import transport as T
from a7ble import commands as C
from a7ble.crc import crc16_arc
from a7ble.framing import parse_frame
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"
E15E = "e606e15e-da3d-6f45-5978-a7a5b8cea2c0"
E15F = "e606e15f-da3d-6f45-5978-a7a5b8cea2c0"
C0C1 = "0000c0c1-0000-1000-8000-00805f9b34fb"
C0C2 = "0000c0c2-0000-1000-8000-00805f9b34fb"


def e606_frame(cmd, payload=b""):
    body = bytes([0xE5, 0x5E, 0x01, cmd, len(payload)]) + payload
    c = crc16_arc(body)
    return body + bytes([c & 0xFF, (c >> 8) & 0xFF])


async def doway_aps():
    p = await asyncio.create_subprocess_exec("system_profiler", "SPAirPortDataType",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    o, _ = await p.communicate()
    return sorted({l.strip().rstrip(":") for l in o.decode(errors="replace").splitlines()
                   if re.search(r"doway", l, re.I)})


async def find_device(t=25.0):
    fut = asyncio.get_event_loop().create_future()
    def cb(d, ad):
        if fut.done(): return
        a = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if a and a.sn.startswith(TARGET_SN): fut.set_result(d)
    sc = BleakScanner(detection_callback=cb); await sc.start()
    try: return await asyncio.wait_for(fut, t)
    finally: await sc.stop()


def pr(b): return "".join(chr(x) if 32 <= x < 127 else "." for x in b)


async def main():
    print(f"扫蓝牙,请让新设备({TARGET_SN})醒着、手机别连它...")
    try: device = await find_device()
    except asyncio.TimeoutError:
        print("超时。"); return
    print(f"找到 {device.name},连接...\n")

    def mk(nm):
        def _cb(_s, data):
            d = bytes(data); f = parse_frame(d)
            tag = f"0x{f.cmd:02x}{'✓' if f.crc_ok else ''}" if f.crc_ok else "raw"
            print(f"   <RX {nm} {tag}> {d.hex(' ')} \"{pr(d)}\"")
        return _cb

    async with BleakClient(device) as client:
        m = {}
        for svc in client.services:
            for ch in svc.characteristics:
                m[ch.uuid.split('-')[0][-4:]] = ch
        for nm in ("b0b2", "c0c2", "e15f"):
            if nm in m:
                try: await client.start_notify(m[nm], mk(nm))
                except Exception as e: print(f"[warn] {nm}: {e}")

        base = await doway_aps(); print(f"基线 Doway 热点: {base or '无'}\n")

        async def w(ch, frame, label):
            if not client.is_connected: print(f"   [断,跳 {label}]"); return
            print(f">>> {label}: {frame.hex(' ')}")
            try: await client.write_gatt_char(m[ch], frame, response=False)
            except Exception as e: print(f"   写失败: {e}")
            await asyncio.sleep(1.5)

        # 旧通道绑定
        await w("b0b1", C.bind("183396".encode(), 0x00), "绑定@b0b1(旧)")
        # e606 上也绑定(E5 5E + cmd 0x03)
        bindpl = "183396".encode().ljust(16, b"\x00") + bytes([0x00])
        await w("e15e", e606_frame(0x03, bindpl), "绑定@e606(E5 5E)")
        # e606 openWifi
        await w("e15e", e606_frame(0x1B, b"\x01"), "openWifi@e606")
        # 再 e606 发一帧 wifiHeart 看是否激活回包
        await w("e15e", e606_frame(0x35), "wifiHeart@e606")
        # 旧通道再查 0x02,重新逼出 0x1F(SSID)
        await w("b0b1", C.get_bind_info(), "0x02查绑定@b0b1(逼 0x1F)")

        print("\n>>> 保活 + 扫热点 24s...")
        hit = None
        for k in range(8):
            if client.is_connected:
                try: await client.write_gatt_char(m["e15e"], e606_frame(0x35), response=False)
                except Exception: pass
            await asyncio.sleep(3.0)
            new = [a for a in await doway_aps() if a not in base]
            if new: print(f"   [{k*3}s] !!! 热点: {new}"); hit = new; break
            print(f"   [{k*3}s] 无热点 (connected={client.is_connected})")

    print(f"\n=== 结论 === Doway 热点: {hit or '未出现'}")


if __name__ == "__main__":
    asyncio.run(main())
