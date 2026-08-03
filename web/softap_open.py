"""真机验收:按开发逆向的 E5 5E 帧开 Soft AP 热点。
连新机 → 旧通道绑定(183396)→ e606 写 openWifi(E5 5E 01 1B 01 01 0E 53)
→ 收 E606E15F 回包 + 扫 Doway 热点;期间 e606 发 wifiHeart 保活。
"""
from __future__ import annotations

import asyncio
import re
import sys
import time

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import transport as T
from a7ble import commands as C
from a7ble.crc import crc16_arc
from a7ble.framing import build_frame, parse_frame
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"
E15E = "e606e15e-da3d-6f45-5978-a7a5b8cea2c0"  # e606 写
E15F = "e606e15f-da3d-6f45-5978-a7a5b8cea2c0"  # e606 通知


def e606_frame(cmd: int, payload: bytes = b"") -> bytes:
    body = bytes([0xE5, 0x5E, 0x01, cmd, len(payload)]) + payload
    c = crc16_arc(body)
    return body + bytes([c & 0xFF, (c >> 8) & 0xFF])


async def doway_aps():
    proc = await asyncio.create_subprocess_exec(
        "system_profiler", "SPAirPortDataType",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    out, _ = await proc.communicate()
    return sorted({l.strip().rstrip(":") for l in out.decode(errors="replace").splitlines()
                   if re.search(r"doway", l, re.I)})


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


def pr(b): return "".join(chr(x) if 32 <= x < 127 else "." for x in b)


async def main():
    print(f"扫蓝牙,请让新设备({TARGET_SN})醒着、手机别连它...")
    try: device = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到。"); return
    print(f"找到 {device.name},连接...\n")

    def mk(nm):
        def _cb(_s, data):
            d = bytes(data); f = parse_frame(d)
            tag = f"0x{f.cmd:02x}" if f.crc_ok else "raw"
            asc = pr(d); flag = "  <<< 可读串!" if re.search(r"[A-Za-z]{4,}", asc) else ""
            print(f"   <RX {nm} {tag}> {d.hex(' ')} \"{asc}\"{flag}")
        return _cb

    async with BleakClient(device) as client:
        m = {}
        for svc in client.services:
            for ch in svc.characteristics:
                m[ch.uuid.split('-')[0][-4:]] = ch
        for nm in ("b0b2", "e15f"):
            if nm in m:
                try: await client.start_notify(m[nm], mk(nm))
                except Exception as e: print(f"[warn] 订阅 {nm}: {e}")

        base = await doway_aps()
        print(f"基线 Doway 热点: {base or '无'}")

        # 1) 旧通道绑定
        print(">>> 绑定 0x03 (183396) @ b0b1")
        await client.write_gatt_char(m["b0b1"], C.bind("183396".encode(), 0x00), response=False)
        await asyncio.sleep(1.5)

        # 2) e606 开热点
        openf = e606_frame(0x1B, b"\x01")
        print(f">>> openWifi @ E606E15E: {openf.hex(' ')}  (connected={client.is_connected})")
        await client.write_gatt_char(m["e15e"], openf, response=False)

        # 3) 保活 + 扫热点
        print(">>> 保活 + 扫 Doway 热点(30s)...")
        hit = None
        for k in range(10):
            if client.is_connected:
                try: await client.write_gatt_char(m["e15e"], e606_frame(0x35), response=False)  # wifiHeart
                except Exception as e: print(f"   heart 写失败: {e}")
            await asyncio.sleep(3.0)
            aps = await doway_aps()
            new = [a for a in aps if a not in base]
            if new:
                print(f"   [{k*3}s] !!! 热点出现: {new}  connected={client.is_connected}")
                hit = new; break
            print(f"   [{k*3}s] 还没 Doway 热点 (connected={client.is_connected})")

    print(f"\n=== 结论 ===")
    print(f"BLE 写 openWifi 后连接是否保持: 见上 connected")
    print(f"Doway 热点: {hit or '未出现'}")
    if hit:
        print("→ 下一步:把 Mac Wi-Fi 连到该热点,GET http://192.168.200.1/get_files")


if __name__ == "__main__":
    asyncio.run(main())
