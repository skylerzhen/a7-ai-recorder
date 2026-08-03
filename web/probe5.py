"""文件下载验证(补 e2e 最后一块):停掉进行中的录音→列表→下载→存盘。

前提:e2e 已启动一条录音 "20260617...". 流程:绑定→0x15确认在录→录几秒→0x07停录(落盘)
→0x0a列表→0x0b取文件→收 B0B4 分片→0x0c停取→存 downloaded.bin。
"""

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
OUT = "/Users/eddie/Desktop/proj/Hospital/web/probe5_out.json"
DL = "/Users/eddie/Desktop/proj/Hospital/web/downloaded.bin"
DONE = "/tmp/a7_probe5_done"
CODE = b"183396"

out = {"events": [], "frames": [], "download": None}
rx = []
file_chunks = []
t0 = 0.0


def ev(m):
    out["events"].append(m)
    print("[p5]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"), timeout=t)


async def send_wait(cl, cmd, frame, wait=2.5):
    st = time.monotonic() - t0
    await cl.write_gatt_char(WRITE, frame, response=False)
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if any(c == cmd and t >= st for t, c, _ in rx):
            break
        await asyncio.sleep(0.05)
    reps = [d for t, c, d in rx if c == cmd and t >= st]
    return reps


async def main():
    global t0
    for p in (DONE, OUT, DL):
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
            out["frames"].append({"cmd": (f.cmd if f.crc_ok else None), "data": (f.data.hex() if f.crc_ok else b.hex())})

        def on4(_s, data):
            file_chunks.append(bytes(data))

        async with BleakClient(dev) as cl:
            await asyncio.sleep(0.3)
            await cl.start_notify(B2, on2)
            await cl.start_notify(B4, on4)
            bind = await send_wait(cl, 0x03, C.bind(CODE), 2.5)
            ev(f"绑定回复={bind[-1].hex() if bind else '无'}")
            rec = await send_wait(cl, 0x15, build_frame(0x15), 2.0)
            ev(f"录音信息 0x15={rec[-1].hex() if rec else '无'}")
            ev("让它再录 4 秒...")
            await asyncio.sleep(4.0)
            stop = await send_wait(cl, 0x07, C.stop_recording(), 3.0)
            ev(f"停录 0x07={stop[-1].hex() if stop else '无回复'}")
            await asyncio.sleep(1.0)
            lst = await send_wait(cl, 0x0A, C.list_files(), 3.0)
            ev(f"文件列表 0x0a 共 {len(lst)} 条: {[d.hex()[:40] for d in lst]}")
            # 提取文件名(0x00+name14+...)
            fname = None
            for d in lst:
                if d and d[0] == 0x00 and len(d) >= 15:
                    fname = d[1:15].split(b"\x00", 1)[0]; break
            if not fname and stop and stop[-1][:1] == b"\x00" and len(stop[-1]) >= 15:
                fname = stop[-1][1:15].split(b"\x00", 1)[0]
            if fname:
                ev(f"下载: {fname!r}")
                file_chunks.clear()
                gf = await send_wait(cl, 0x0B, C.get_file(fname.decode("ascii", "replace"), 0), 3.0)
                ev(f"取文件 0x0b 回复={gf[-1].hex() if gf else '无'};收 B0B4 中...")
                await asyncio.sleep(8.0)
                await send_wait(cl, 0x0C, build_frame(0x0C), 2.0)
                blob = b"".join(file_chunks)
                if blob:
                    open(DL, "wb").write(blob)
                    out["download"] = {"name": fname.decode("ascii", "replace"), "bytes": len(blob), "chunks": len(file_chunks), "head_hex": blob[:16].hex()}
                    ev(f"下载完成 {len(blob)} 字节 / {len(file_chunks)} 分片")
                else:
                    out["download"] = {"name": fname.decode("ascii", "replace"), "bytes": 0, "note": "B0B4 无数据"}
                    ev("B0B4 无数据")
            else:
                ev("列表无已存文件,无法下载")
            ev(f"末态 connected={cl.is_connected} elapsed={round(time.monotonic()-t0,1)}s")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev(f"写出 {OUT}")


asyncio.run(main())
