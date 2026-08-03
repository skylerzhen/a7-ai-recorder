"""Soft AP 逆向 step6:锁定 0x1f(Wi-Fi 命令族)。
绑定(183396)→ 多种方式戳 0x1f(读/带01开启)→ 扫 Doway 热点。
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


async def wifi_doway():
    proc = await asyncio.create_subprocess_exec(
        "system_profiler", "SPAirPortDataType",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    out, _ = await proc.communicate()
    return [l.strip().rstrip(":") for l in out.decode(errors="replace").splitlines()
            if re.search(r"doway|q95|x95|ainote", l, re.I)]


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
            d = bytes(data); asc = pr(d)
            f = parse_frame(d)
            tag = f"0x{f.cmd:02x}" if f.crc_ok else "raw"
            flag = "  <<< 可读串!" if re.search(r"[A-Za-z]{4,}", asc) else ""
            print(f"     <RX {nm} {tag}> {d.hex(' ')} \"{asc}\"{flag}")
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

        async def send(cmd, data=b"", label=""):
            if not client.is_connected:
                print(f"   [断,跳过 {label or hex(cmd)}]"); return
            fr = build_frame(cmd, data)
            print(f">>> {label or ('0x%02x'%cmd)} data={data.hex(' ') or '空'}: {fr.hex(' ')}")
            try: await client.write_gatt_char(m["b0b1"], fr, response=False)
            except Exception as e: print(f"   写失败: {e}")
            await asyncio.sleep(1.3)

        # 先绑定
        await send(C.CMD_BIND >> 0, b"", label="(占位)") if False else None
        print(">>> 绑定 0x03 (183396)")
        await client.write_gatt_char(m["b0b1"], C.bind("183396".encode(), 0x00), response=False)
        await asyncio.sleep(1.3)

        # 戳 0x1f 各种姿势
        await send(0x1f, b"", "0x1f 读")
        await send(0x1f, b"\x01", "0x1f 开(01)")
        # 邻近也试(0x1e/0x20 可能是 wifi on/off 配套)
        await send(0x1e, b"\x01", "0x1e 开(01)")
        await send(0x20, b"\x01", "0x20 开(01)")

        print("\n>>> 维持连接 20s,每 4s 扫一次 Doway 热点 + 重读 0x1f...")
        hit = None
        for k in range(5):
            if client.is_connected:
                try: await client.write_gatt_char(m["b0b1"], build_frame(0x1f), response=False)
                except Exception: pass
            await asyncio.sleep(4.0)
            dw = await wifi_doway()
            if dw:
                print(f"    [{k*4}s] !!! 发现热点: {dw}"); hit = dw; break
            print(f"    [{k*4}s] 还没 Doway 热点 (connected={client.is_connected})")

    print(f"\n=== 结论 ===  Doway 热点: {hit or '未出现'}")


if __name__ == "__main__":
    asyncio.run(main())
