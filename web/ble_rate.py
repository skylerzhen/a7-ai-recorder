"""实测新机 BLE 实时流(B0B3)吞吐与延迟:0x06 开录 → 记录每个通知到达时刻
→ 算 通知速率 / 字节速率 / 88B 记录速率 / 包间隔抖动 / 有效音频时长。"""
from __future__ import annotations
import asyncio, sys, time, statistics
from bleak import BleakScanner, BleakClient
sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import commands as C
from a7ble import transport as T
from a7ble.advert import parse_from_bleak

TARGET_SN = "Q95HA00078"
LISTEN_S = 15.0


async def find_device(timeout=25.0):
    fut = asyncio.get_event_loop().create_future()
    def cb(d, ad):
        if fut.done(): return
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if adv and adv.sn.startswith(TARGET_SN): fut.set_result(d)
    s = BleakScanner(detection_callback=cb); await s.start()
    try: return await asyncio.wait_for(fut, timeout)
    finally: await s.stop()


async def main():
    print(f"扫描新机({TARGET_SN})… 请确保它醒着、且 App 已【断开】(BLE 同时只能连一个)")
    try: device = await find_device()
    except asyncio.TimeoutError:
        print("✗ 没扫到。确认设备醒着、App 已断开,再重跑。"); return
    print(f"✓ 连 {device.name}")

    notes = []          # (到达时刻, 字节数)
    buf = bytearray()
    t0 = None
    def rt_cb(_s, data):
        nonlocal t0
        now = time.monotonic()
        if t0 is None: t0 = now
        notes.append((now, len(data))); buf.extend(bytes(data))

    async with BleakClient(device) as client:
        # 尝试协商大 MTU(Android/桌面 bleak 支持;决定单通知能否装下整条 88B 记录)
        try: mtu = client.mtu_size
        except Exception: mtu = None
        await client.start_notify(T.CHAR_NOTIFY_RT, rt_cb)
        name = "20260629000099"
        frame = C.start_recording(name, 0)
        print(f">>> 0x06 开录: {frame.hex(' ')}  | MTU={mtu}")
        await client.write_gatt_char(T.CHAR_WRITE, frame, response=False)
        await asyncio.sleep(LISTEN_S)
        print(">>> 0x07 停录")
        await client.write_gatt_char(T.CHAR_WRITE, C.stop_recording(), response=False)
        await asyncio.sleep(0.5)
        try: await client.stop_notify(T.CHAR_NOTIFY_RT)
        except Exception: pass

    n = len(notes)
    total = sum(b for _, b in notes)
    if n < 2:
        print(f"✗ 只收到 {n} 个通知 / {total}B —— 实时流没起来(可能需先绑定或本机型通道不同)"); return
    span = notes[-1][0] - notes[0][0]
    gaps = [notes[i+1][0] - notes[i][0] for i in range(n-1)]
    gaps_ms = [g*1000 for g in gaps]

    print("\n================ 实测结果 ================")
    print(f"采集时长(首末通知间)         : {span:.2f}s")
    print(f"通知数                        : {n}  → {n/span:.1f} 个/秒")
    print(f"总字节                        : {total}B  → {total/span/1024:.2f} KB/s  ({total*8/span/1000:.1f} kbps)")
    print(f"单通知平均大小                : {total/n:.1f}B  (88B 记录能否单包装下看这个)")
    print(f"按 88B 记录算                 : {total/88:.0f} 条  → {total/88/span:.1f} 条/秒  (满速应≈50/秒)")
    print(f"有效音频时长(条数×20ms)      : {total/88*0.02:.2f}s  vs 采集 {span:.2f}s")
    print(f"包间隔  中位={statistics.median(gaps_ms):.1f}ms  均值={statistics.mean(gaps_ms):.1f}ms  "
          f"max={max(gaps_ms):.1f}ms  p95={sorted(gaps_ms)[int(len(gaps_ms)*0.95)]:.1f}ms")
    print(f"BLE 容量占用估计              : 实测 {total/span/1024:.1f}KB/s,BLE 实测上限通常 10–100KB/s → 余量大")
    open("/tmp/rt_rate.bin", "wb").write(bytes(buf))
    print(f"原始流已存 /tmp/rt_rate.bin ({len(buf)}B)")


if __name__ == "__main__":
    asyncio.run(main())
