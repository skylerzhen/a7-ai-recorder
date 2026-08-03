"""文件下载吞吐测试:列表挑最大文件,计时下载,算 KB/s。"""

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
WRITE, B2, B4 = U(0xB0B1), U(0xB0B2), U(0xB0B4)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/dlspeed_out.json"
DONE = "/tmp/a7_dlspeed_done"
CODE = b"183396"
AUDIO_BPS = 4000.0

out = {"events": [], "files": [], "download": None}
rx = []
b4 = []
t0 = 0.0


def ev(m):
    out["events"].append(m)
    print("[dl]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"), timeout=t)


async def send(cl, frame):
    await cl.write_gatt_char(WRITE, frame, response=False)


def frames_since(cmd, since):
    return [d for t, c, d in rx if c == cmd and t >= since]


async def collect_list(cl, settle=3.0):
    """发 0x0a,收集所有条目帧直到 0x02 结束或超时。"""
    st = time.monotonic() - t0
    await send(cl, C.list_files())
    end = time.monotonic() + settle
    files = []
    seen_end = False
    while time.monotonic() < end and not seen_end:
        for d in frames_since(0x0A, st):
            if d[:1] == b"\x00" and len(d) >= 19:
                name = d[1:15].split(b"\x00", 1)[0]
                size = int.from_bytes(d[15:19], "big")
                e = {"name": name.decode("ascii", "replace"), "size": size}
                if e not in files:
                    files.append(e)
            elif d[:1] == b"\x02":
                seen_end = True
        await asyncio.sleep(0.1)
    return files


async def main():
    global t0
    for p in (DONE, OUT):
        try:
            os.remove(p)
        except OSError:
            pass
    ev("扫描(点按键唤醒)")
    dev = await find(45.0)
    if not dev:
        ev("没找到设备")
    else:
        t0 = time.monotonic()

        def on2(_s, data):
            b = bytes(data); f = parse_frame(b)
            rx.append((time.monotonic() - t0, f.cmd if f.crc_ok else -1, f.data if f.crc_ok else b))

        def on4(_s, data):
            b4.append((time.monotonic() - t0, len(data)))

        async with BleakClient(dev) as cl:
            await asyncio.sleep(0.3)
            await cl.start_notify(B2, on2)
            await cl.start_notify(B4, on4)
            await send(cl, C.bind(CODE)); await asyncio.sleep(1.5)
            ev(f"绑定={ (frames_since(0x03,0)[-1:] or [b''])[0].hex() }")

            files = await collect_list(cl, 4.0)
            # 若空,可能在录音,先停录再列
            if not files:
                ev("列表空,尝试停录后再列...")
                st = time.monotonic() - t0
                await send(cl, C.stop_recording())
                for _ in range(8):
                    await asyncio.sleep(2.0)
                    files = await collect_list(cl, 2.0)
                    if files:
                        break
            out["files"] = files
            ev(f"文件 {len(files)} 个: {files}")
            if files:
                tgt = max(files, key=lambda f: f["size"])
                name, size = tgt["name"], tgt["size"]
                ev(f"下载最大文件 {name} ({size}B ≈{round(size/AUDIO_BPS,1)}s)")
                b4.clear()
                await send(cl, C.get_file(name, 0))
                deadline = time.monotonic() + 60
                last = -1; stall = 0
                while time.monotonic() < deadline:
                    got = sum(n for _, n in b4)
                    if size and got >= size:
                        break
                    if got == last:
                        stall += 1
                        if stall >= 30 and got > 0:
                            break
                    else:
                        stall = 0; last = got
                    await asyncio.sleep(0.1)
                await send(cl, build_frame(0x0C))
                got = sum(n for _, n in b4)
                dl_wall = (b4[-1][0] - b4[0][0]) if len(b4) >= 2 else 0.001
                Bps = got / dl_wall if dl_wall > 0 else 0
                out["download"] = {
                    "file": name, "size": size, "got": got, "complete": bool(size and got >= size),
                    "transfer_s": round(dl_wall, 2), "KBps": round(Bps / 1024, 1), "kbps": round(Bps * 8 / 1000, 1),
                    "packets": len(b4), "avg_pkt": round(got / len(b4), 1) if b4 else 0,
                    "speedup_vs_realtime": round(Bps / AUDIO_BPS, 1) if Bps else 0,
                    "sec_to_pull_1h_audio": round((3600 * AUDIO_BPS) / Bps, 1) if Bps else None,
                }
                d = out["download"]
                ev(f"吞吐: {got}/{size}B 传输 {d['transfer_s']}s = {d['KBps']}KB/s ({d['kbps']}kbps), 比实时快 {d['speedup_vs_realtime']}x")
                ev(f"  → 下载1小时录音约需 {d['sec_to_pull_1h_audio']}s;包 {d['packets']}个/{d['avg_pkt']}B")
            else:
                ev("无文件可测")
            ev(f"完成 elapsed={round(time.monotonic()-t0,1)}s")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev("写出 dlspeed_out.json")


asyncio.run(main())
