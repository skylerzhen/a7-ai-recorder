"""性能测试:实时流速率/实时性 + 文件下载吞吐 + MTU + 命令延迟 + 连接耗时。"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakClient, BleakScanner  # noqa: E402
from a7ble import commands as C  # noqa: E402
from a7ble.framing import build_frame, parse_frame  # noqa: E402
from a7ble.advert import COMPANY_ID  # noqa: E402

U = lambda x: f"0000{x:04x}-0000-1000-8000-00805f9b34fb"
WRITE, B2, B3, B4 = U(0xB0B1), U(0xB0B2), U(0xB0B3), U(0xB0B4)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/perf_out.json"
LIVE = "/Users/eddie/Desktop/proj/Hospital/web/live_b3.mp3"
DONE = "/tmp/a7_perf_done"
CODE = b"183396"
AUDIO_BPS = 4000.0  # 32kbps = 4000 B/s

out = {"events": [], "metrics": {}}
rx = []
b3 = []   # (t, nbytes)
b4 = []   # (t, nbytes)
b3_buf = bytearray()
t0 = 0.0


def ev(m):
    out["events"].append(m)
    print("[perf]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"), timeout=t)


async def send_wait(cl, cmd, frame, wait=3.0):
    st = time.monotonic() - t0
    await cl.write_gatt_char(WRITE, frame, response=False)
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if any(c == cmd and t >= st for t, c, _ in rx):
            break
        await asyncio.sleep(0.02)
    reps = [d for t, c, d in rx if c == cmd and t >= st]
    return reps[-1] if reps else None


async def main():
    global t0
    for p in (DONE, OUT, LIVE):
        try:
            os.remove(p)
        except OSError:
            pass
    ev("扫描(点按键唤醒)")
    dev = await find(45.0)
    if not dev:
        ev("没找到设备")
        json.dump(out, open(OUT, "w"), ensure_ascii=False)
        open(DONE, "w").write("x")
        return
    t0 = time.monotonic()

    def on2(_s, data):
        b = bytes(data); f = parse_frame(b)
        rx.append((time.monotonic() - t0, f.cmd if f.crc_ok else -1, f.data if f.crc_ok else b))

    def on3(_s, data):
        b3.append((time.monotonic() - t0, len(data))); b3_buf.extend(bytes(data))

    def on4(_s, data):
        b4.append((time.monotonic() - t0, len(data)))

    tc = time.monotonic()
    async with BleakClient(dev) as cl:
        out["metrics"]["connect_s"] = round(time.monotonic() - tc, 3)
        try:
            out["metrics"]["mtu"] = cl.mtu_size
        except Exception:
            out["metrics"]["mtu"] = None
        await asyncio.sleep(0.3)
        await cl.start_notify(B2, on2)

        tb = time.monotonic()
        bind = await send_wait(cl, 0x03, C.bind(CODE), 2.5)
        out["metrics"]["bind_s"] = round(time.monotonic() - tb, 3)
        ev(f"连接 {out['metrics']['connect_s']}s, MTU={out['metrics']['mtu']}, 绑定 {out['metrics']['bind_s']}s = {(bind or b'').hex()}")

        # 命令往返延迟:5 次 0x05
        lat = []
        for _ in range(5):
            s = time.monotonic()
            r = await send_wait(cl, 0x05, C.get_device_info(), 2.0)
            if r is not None:
                lat.append((time.monotonic() - s) * 1000)
            await asyncio.sleep(0.1)
        if lat:
            out["metrics"]["latency_ms"] = {"avg": round(sum(lat) / len(lat), 1), "min": round(min(lat), 1), "max": round(max(lat), 1), "n": len(lat)}
            ev(f"命令往返延迟: avg {out['metrics']['latency_ms']['avg']}ms (min {out['metrics']['latency_ms']['min']} / max {out['metrics']['latency_ms']['max']})")

        # 确保在录音
        r15 = await send_wait(cl, 0x15, build_frame(0x15), 2.0)
        if not (r15 and r15[:1] == b"\x00"):
            await send_wait(cl, 0x06, C.start_recording("PERFTEST", 1), 3.0)
            ev("已开录")
        else:
            ev("设备已在录音")

        # 实时流测试:订阅 B3,采 15s
        await cl.start_notify(B3, on3)
        b3.clear(); b3_buf.clear()
        WIN = 15.0
        ev(f"采集实时流 B0B3 {WIN}s(请对着设备说话)...")
        ts = time.monotonic()
        await asyncio.sleep(WIN)
        await cl.stop_notify(B3)
        tot = sum(n for _, n in b3); wall = time.monotonic() - ts
        Bps = tot / wall if wall else 0
        out["metrics"]["realtime"] = {
            "wall_s": round(wall, 2), "bytes": tot, "packets": len(b3),
            "Bps": round(Bps, 1), "kbps": round(Bps * 8 / 1000, 1),
            "avg_pkt": round(tot / len(b3), 1) if b3 else 0,
            "pkts_per_s": round(len(b3) / wall, 1) if wall else 0,
            "audio_s_received": round(tot / AUDIO_BPS, 2),
            "realtime_factor": round((tot / AUDIO_BPS) / wall, 3) if wall else 0,
        }
        # 每秒字节profile
        prof = {}
        for t, n in b3:
            prof[int(t - (ts - t0))] = prof.get(int(t - (ts - t0)), 0) + n
        out["metrics"]["realtime"]["per_s_bytes"] = [prof.get(i, 0) for i in range(int(WIN) + 1)]
        if b3_buf:
            s = next((k for k in range(min(len(b3_buf), 4000) - 1) if b3_buf[k] == 0xFF and (b3_buf[k + 1] & 0xE0) == 0xE0), 0)
            open(LIVE, "wb").write(bytes(b3_buf[s:]))
        m = out["metrics"]["realtime"]
        ev(f"实时流: {m['bytes']}B / {m['wall_s']}s = {m['Bps']}B/s ({m['kbps']}kbps), 包 {m['packets']}个({m['avg_pkt']}B/个,{m['pkts_per_s']}/s), 实时系数 {m['realtime_factor']}")

        # 文件下载吞吐:停录→列表→下载,计时
        stop = await send_wait(cl, 0x07, C.stop_recording(), 5.0)
        await asyncio.sleep(1.0)
        name, size = None, 0
        if stop and stop[:1] == b"\x00" and len(stop) >= 19:
            name = stop[1:15].split(b"\x00", 1)[0]; size = int.from_bytes(stop[15:19], "big")
        if not name:
            lst = await send_wait(cl, 0x0A, C.list_files(), 3.0)
            if lst and lst[:1] == b"\x00" and len(lst) >= 19:
                name = lst[1:15].split(b"\x00", 1)[0]; size = int.from_bytes(lst[15:19], "big")
        if name:
            b4.clear()
            td = time.monotonic()
            await cl.start_notify(B4, on4)
            await send_wait(cl, 0x0B, C.get_file(name.decode("ascii", "replace"), 0), 3.0)
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline:
                got = sum(n for _, n in b4)
                if size and got >= size:
                    break
                await asyncio.sleep(0.1)
            await send_wait(cl, 0x0C, build_frame(0x0C), 2.0)
            got = sum(n for _, n in b4)
            # 传输时间 = 第一个分片到最后一个分片
            if len(b4) >= 2:
                dl_wall = b4[-1][0] - b4[0][0]
            else:
                dl_wall = time.monotonic() - td
            dlBps = got / dl_wall if dl_wall > 0 else 0
            out["metrics"]["download"] = {
                "file": name.decode("ascii", "replace"), "size": size, "got": got,
                "complete": bool(size and got >= size), "wall_s": round(dl_wall, 2),
                "KBps": round(dlBps / 1024, 1), "kbps": round(dlBps * 8 / 1000, 1),
                "packets": len(b4), "avg_pkt": round(got / len(b4), 1) if b4 else 0,
                "min_per_audio_min": round((60 * AUDIO_BPS) / dlBps / 60, 2) if dlBps else None,
                "speedup_vs_realtime": round(dlBps / AUDIO_BPS, 1) if dlBps else 0,
            }
            d = out["metrics"]["download"]
            ev(f"下载吞吐: {got}/{size}B 用 {d['wall_s']}s = {d['KBps']}KB/s ({d['kbps']}kbps), 比实时快 {d['speedup_vs_realtime']}x, 包{d['packets']}个/{d['avg_pkt']}B")
        else:
            ev("无文件可测下载")

        ev(f"完成 elapsed={round(time.monotonic()-t0,1)}s connected={cl.is_connected}")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev("写出 perf_out.json")


asyncio.run(main())
