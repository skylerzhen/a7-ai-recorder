"""Soft AP 逆向 step4:把"当前=关"的候选设置命令带 0x01 写使能,逐个看是否开出热点。
非 Wi-Fi 的立即写 0x00 还原。开出热点或 BLE 断连即疑似命中。
"""
from __future__ import annotations

import asyncio
import re
import sys
import time

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import transport as T
from a7ble.framing import build_frame, parse_frame
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"
# 上一轮返回 00(关)的候选 + 0x19(无回包,可能要 data)
CANDIDATES = [0x10, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b]


async def wifi_ssids():
    proc = await asyncio.create_subprocess_exec(
        "system_profiler", "SPAirPortDataType",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    out, _ = await proc.communicate()
    lines = out.decode(errors="replace").splitlines()
    s = set()
    for i, ln in enumerate(lines):
        t = ln.strip()
        if t.endswith(":") and i+1 < len(lines) and "PHY Mode:" in lines[i+1]:
            s.add(t[:-1])
    return s


async def find_device(timeout=25.0):
    fut = asyncio.get_event_loop().create_future()
    def cb(device, ad):
        if fut.done(): return
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if adv and adv.sn.startswith(TARGET_SN):
            fut.set_result(device)
    sc = BleakScanner(detection_callback=cb)
    await sc.start()
    try: return await asyncio.wait_for(fut, timeout)
    finally: await sc.stop()


def pr(b): return "".join(chr(x) if 32<=x<127 else "." for x in b)


async def main():
    base = await wifi_ssids()
    print(f"Wi-Fi 基线 {len(base)} 个: {sorted(base)}")
    print(f"扫蓝牙,请让新设备({TARGET_SN})醒着、手机别连它...")
    try: device = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到。"); return
    print(f"找到 {device.name},连接...\n")

    rx = []
    def mk(nm):
        def _cb(_s, data):
            rx.append((nm, bytes(data)))
            asc = pr(bytes(data))
            flag = "  <<< 可读串!" if re.search(r"[A-Za-z]{4,}", asc) else ""
            print(f"     <RX {nm}> {bytes(data).hex(' ')} \"{asc}\"{flag}")
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

        async def w(cmd, data):
            if not client.is_connected: return False
            try:
                await client.write_gatt_char(m["b0b1"], build_frame(cmd, data), response=False)
                return True
            except Exception as e:
                print(f"     写失败: {e}"); return False

        hit = None
        for cmd in CANDIDATES:
            if not client.is_connected:
                print(f">>> 0x{cmd:02x} 之前连接已断 —— 上一条可能就是 Wi-Fi(切 radio 致断)!")
                break
            print(f">>> 使能 0x{cmd:02x} (data=01)")
            await w(cmd, b"\x01")
            await asyncio.sleep(2.0)
            connected = client.is_connected
            now = await wifi_ssids()
            new = now - base
            if new:
                print(f"    !!! 命中?新热点: {sorted(new)}  (cmd=0x{cmd:02x})")
                hit = (cmd, sorted(new)); break
            if not connected:
                print(f"    BLE 在使能 0x{cmd:02x} 后断连 —— 疑似切 Wi-Fi/重启 radio,重点排查这条")
                hit = (cmd, "BLE断连"); break
            print(f"    无热点、连接仍在 → 还原 0x{cmd:02x}=00")
            await w(cmd, b"\x00")
            await asyncio.sleep(0.8)

        if hit is None and client.is_connected:
            # 再多等一会,Wi-Fi 起来可能有延迟
            print("\n>>> 全部试完无明显命中,再观察 8s...")
            for k in range(4):
                await asyncio.sleep(2.0)
                new = (await wifi_ssids()) - base
                if new: print(f"    [{k*2}s] 新热点: {sorted(new)}"); hit=("延迟",sorted(new)); break
                else: print(f"    [{k*2}s] 无")

    print(f"\n=== 结论 ===")
    final = await wifi_ssids()
    print(f"Wi-Fi 新增: {sorted(final - base) or '无'}")
    print(f"命中: {hit}")


if __name__ == "__main__":
    asyncio.run(main())
