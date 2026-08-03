"""新硬件实时流兼容测试:发 0x06 开录,收 B0B3 实时分片,验是否仍是 MP3。"""
from __future__ import annotations

import asyncio
import sys
import time

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import commands as C
from a7ble import transport as T
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"
LISTEN_S = 8.0


def mp3_sync_off(buf: bytes) -> int:
    for i in range(len(buf) - 1):
        if buf[i] == 0xFF and (buf[i + 1] & 0xE0) == 0xE0:
            return i
    return -1


async def find_device(timeout=20.0):
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


async def main():
    print(f"扫描中,请按一下新设备({TARGET_SN})唤醒并保持醒着...")
    try:
        device = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到目标设备。")
        return
    print(f"找到 {device.name}({device.address}),连接...")

    rt_bytes = bytearray()
    cmd_pkts = []
    t0 = time.monotonic()

    def rt_cb(_s, data):
        rt_bytes.extend(bytes(data))

    def cmd_cb(_s, data):
        cmd_pkts.append((time.monotonic() - t0, bytes(data)))

    async with BleakClient(device) as client:
        await client.start_notify(T.CHAR_NOTIFY_RT, rt_cb)    # B0B3 实时流
        await client.start_notify(T.CHAR_NOTIFY_CMD, cmd_cb)  # B0B2 指令回包
        name = "20260629000001"  # 14 ASCII
        frame = C.start_recording(name, 0)
        print(f">>> 0x06 开录 name={name!r}: {frame.hex(' ')}")
        await client.write_gatt_char(T.CHAR_WRITE, frame, response=False)
        await asyncio.sleep(LISTEN_S)
        print(">>> 0x07 停录")
        await client.write_gatt_char(T.CHAR_WRITE, C.stop_recording(), response=False)
        await asyncio.sleep(1.0)
        try:
            await client.stop_notify(T.CHAR_NOTIFY_RT)
            await client.stop_notify(T.CHAR_NOTIFY_CMD)
        except Exception:
            pass

    print(f"\n=== B0B2 指令回包 {len(cmd_pkts)} 个 ===")
    for t, d in cmd_pkts:
        print(f"  [{t:6.3f}s] {d.hex(' ')}")

    print(f"\n=== B0B3 实时流:{len(rt_bytes)} 字节 / {LISTEN_S}s ===")
    if not rt_bytes:
        print("  (没收到实时数据 —— 0x06 可能要先绑定,或本机型实时通道不同)")
        return
    off = mp3_sync_off(bytes(rt_bytes[:64]))
    print(f"  前 32B: {bytes(rt_bytes[:32]).hex(' ')}")
    print(f"  MP3 帧同步(0xFFEx)偏移: {off}  → {'✅ 是 MP3 流' if off >= 0 else '⚠️ 头部未见 MP3 同步'}")
    rate = len(rt_bytes) / LISTEN_S
    print(f"  平均码率 ≈ {rate*8/1000:.1f} kbps(旧机 B0B3 标称 32kbps/16kHz/mono)")
    with open("/tmp/new_hw_stream.bin", "wb") as f:
        f.write(rt_bytes)
    print("  原始流已存 /tmp/new_hw_stream.bin")


if __name__ == "__main__":
    asyncio.run(main())
