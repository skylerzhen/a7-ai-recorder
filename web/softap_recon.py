"""Soft AP 逆向 step1:无损侦察。
dump 全部 GATT 服务/特征 + 读所有可读特征值 + 读描述符,找 Wi-Fi/SoftAP 控制通道。
重点:新机比旧机多的两个服务 c0c0 / e606e15d…
"""
from __future__ import annotations

import asyncio
import sys

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"


async def find_device(timeout=25.0):
    fut = asyncio.get_event_loop().create_future()

    def cb(device, ad):
        if fut.done():
            return
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if adv and adv.sn.startswith(TARGET_SN):
            fut.set_result(device)

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    try:
        return await asyncio.wait_for(fut, timeout)
    finally:
        await scanner.stop()


def printable(b: bytes) -> str:
    return "".join(chr(x) if 32 <= x < 127 else "." for x in b)


async def main():
    print(f"扫描中,请让新设备({TARGET_SN})醒着、手机别连它...")
    try:
        device = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到目标设备。")
        return
    print(f"找到 {device.name}({device.address}),连接侦察...\n")

    async with BleakClient(device) as client:
        for svc in client.services:
            su = svc.uuid
            tag = ""
            if su.startswith("0000b0b0"):
                tag = "  ← 旧控制服务(已知)"
            elif su.startswith("0000c0c0") or su.startswith("e606e15d"):
                tag = "  <<< 新服务(疑似 Wi-Fi/SoftAP)"
            print(f"SERVICE {su}{tag}")
            for ch in svc.characteristics:
                props = ",".join(ch.properties)
                short = ch.uuid.split("-")[0][-4:]
                line = f"  CHAR {short} [{props}]"
                # 读可读特征
                if "read" in ch.properties:
                    try:
                        val = await client.read_gatt_char(ch)
                        line += f"\n        READ {len(val)}B: {val.hex(' ')}"
                        line += f'\n        ascii: "{printable(val)}"'
                    except Exception as e:
                        line += f"\n        READ 失败: {e}"
                # 读描述符(可能有 CUD 人类可读名)
                for d in ch.descriptors:
                    try:
                        dv = await client.read_gatt_descriptor(d.handle)
                        if d.uuid.startswith("00002901"):  # Characteristic User Description
                            line += f'\n        [名称] "{printable(dv)}"'
                    except Exception:
                        pass
                print(line)
            print()


if __name__ == "__main__":
    asyncio.run(main())
