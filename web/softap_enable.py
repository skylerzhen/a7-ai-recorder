"""Soft AP 逆向 step3:在稳定的 B0B0 通道上试探"开启 Wi-Fi"命令。
- 先空连 3.5s,判断断连是否写触发
- 扫候选命令号(避开 0x0d 删除),看回包(尤其 ASCII=SSID/密码线索)+ 连接态
- 前后扫 Wi-Fi,对比是否冒出设备热点
安全:仅发无 data 的命令帧;一旦设备异常立即停。
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


async def wifi_ssids():
    """system_profiler 抓当前可见 SSID 集合。"""
    proc = await asyncio.create_subprocess_exec(
        "system_profiler", "SPAirPortDataType",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
    out, _ = await proc.communicate()
    lines = out.decode(errors="replace").splitlines()
    ssids = set()
    for i, ln in enumerate(lines):
        s = ln.strip()
        if s.endswith(":") and i + 1 < len(lines) and "PHY Mode:" in lines[i + 1]:
            ssids.add(s[:-1])
    return ssids


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
    print("扫 Wi-Fi 基线...")
    base = await wifi_ssids()
    print(f"  基线 {len(base)} 个 SSID")

    print(f"\n扫蓝牙,请让新设备({TARGET_SN})醒着、手机别连它...")
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
            asc = pr(bytes(data))
            flag = "  <<< 含可读串!" if re.search(r"[A-Za-z]{4,}", asc) else ""
            print(f"   <RX {name}> {bytes(data).hex(' ')}  \"{asc}\"{flag}")
        return _cb

    async with BleakClient(device) as client:
        m = {}
        for svc in client.services:
            for ch in svc.characteristics:
                m[ch.uuid.split('-')[0][-4:]] = ch
        for nm in ("b0b2","c0c2","e15f"):
            if nm in m:
                try: await client.start_notify(m[nm], mk(nm))
                except Exception as e: print(f"[warn] 订阅 {nm} 失败: {e}")

        # ① 空连观察:断连是否写触发
        print(">>> 空连观察 3.5s(不发任何命令)...")
        await asyncio.sleep(3.5)
        print(f"    空连后 is_connected={client.is_connected}")
        if not client.is_connected:
            print("    → 连上就会自动断,之前的断连不是写触发。需另想 keepalive。")
            return

        # ② B0B0 试探候选开启命令(避开 0x0d 删除)
        candidates = [0x0e,0x10,0x11,0x12,0x13,0x14,0x15,0x16,0x17,0x18,0x19,0x1a,0x1b,0x1c,0x1d,0x1e,0x1f,0x20]
        print("\n>>> 在 B0B0(b0b1)逐条试探:")
        for cmd in candidates:
            if not client.is_connected:
                print(f"    [连接已断于 0x{cmd:02x} 之前,停]"); break
            frame = build_frame(cmd)
            print(f"  → cmd=0x{cmd:02x}: {frame.hex(' ')}")
            try:
                await client.write_gatt_char(m["b0b1"], frame, response=False)
            except Exception as e:
                print(f"    写失败: {e} (connected={client.is_connected})"); break
            await asyncio.sleep(1.0)

        # ③ 保持连接 + 周期 keepalive,等热点起来,期间反复扫 Wi-Fi
        print("\n>>> 维持连接 18s,监测是否冒出设备热点...")
        for k in range(6):
            if client.is_connected:
                try: await client.write_gatt_char(m["b0b1"], build_frame(0x05), response=False)
                except Exception: pass
            await asyncio.sleep(3.0)
            now = await wifi_ssids()
            new = now - base
            if new:
                print(f"    [{k*3}s] 新出现 SSID: {sorted(new)}")
            else:
                print(f"    [{k*3}s] 暂无新热点(connected={client.is_connected})")

    print(f"\n=== 回包汇总 {len(pkts)} 个 ===")
    for t, name, d in pkts:
        f = parse_frame(d)
        tag = f"cmd=0x{f.cmd:02x} crc_ok" if f.crc_ok else "raw"
        print(f"  [{t:6.3f}s] {name}  {d.hex(' ')}  <{tag}>  \"{pr(d)}\"")

    final = await wifi_ssids()
    print(f"\n=== Wi-Fi 前后对比 ===  新增: {sorted(final - base) or '无'}")


if __name__ == "__main__":
    asyncio.run(main())
