"""Soft AP 逆向 step2b:稳健版。用特征对象写、每步查连接态、一次一条。
先专攻 c0c1(命名与 b0b0 平行,最可能同协议),发 0x05 看 c0c2 回什么。
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
SVC_C0C0 = "0000c0c0-0000-1000-8000-00805f9b34fb"
SVC_E606 = "e606e15d-da3d-6f45-5978-a7a5b8cea2c0"


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
            print(f"   <RX {name}> {bytes(data).hex(' ')}  \"{pr(bytes(data))}\"")
        return _cb

    def chmap(client):
        m = {}
        for svc in client.services:
            for ch in svc.characteristics:
                m[ch.uuid.split('-')[0][-4:]] = ch
        return m

    async with BleakClient(device) as client:
        m = chmap(client)
        # 订阅所有 notify
        for nm in ("b0b2","c0c2","e15f"):
            if nm in m:
                try: await client.start_notify(m[nm], mk(nm))
                except Exception as e: print(f"[warn] 订阅 {nm} 失败: {e}")

        async def send(wch, cmd, data=b""):
            if not client.is_connected:
                print(f"   [连接已断,跳过 0x{cmd:02x}]"); return False
            frame = build_frame(cmd, data)
            print(f">>> {wch} cmd=0x{cmd:02x}: {frame.hex(' ')}")
            try:
                await client.write_gatt_char(m[wch], frame, response=False)
            except Exception as e:
                print(f"   写失败: {e} (is_connected={client.is_connected})"); return False
            await asyncio.sleep(1.5)
            return True

        # 先只攻 c0c1,逐条发、断了就停
        for cmd in (0x05, 0x01, 0x02, 0x0f, 0x03):
            if "c0c1" not in m: break
            if not await send("c0c1", cmd):
                break
        # c0c1 若全程没断,再试 e15e
        if client.is_connected and "e15e" in m:
            print("\n--- c0c1 稳定,转 e15e ---")
            for cmd in (0x05, 0x01, 0x02, 0x0f):
                if not await send("e15e", cmd): break

        await asyncio.sleep(2.0)
        print(f"\n连接状态: is_connected={client.is_connected}")

    print(f"\n=== 汇总 {len(pkts)} 个回包 ===")
    for t, name, d in pkts:
        f = parse_frame(d)
        tag = f"cmd=0x{f.cmd:02x} crc_ok" if f.crc_ok else "raw"
        print(f"  [{t:6.3f}s] {name}  {d.hex(' ')}  <{tag}>  \"{pr(d)}\"")


if __name__ == "__main__":
    asyncio.run(main())
