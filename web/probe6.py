"""下载验证 v2(更有耐心):停录后轮询文件列表等落盘,并用 0x15 报的文件名直下作双保险。"""

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
OUT = "/Users/eddie/Desktop/proj/Hospital/web/probe6_out.json"
DL = "/Users/eddie/Desktop/proj/Hospital/web/downloaded.bin"
DONE = "/tmp/a7_probe6_done"
CODE = b"183396"

out = {"events": [], "frames": [], "download": None}
rx = []
file_chunks = []
t0 = 0.0


def ev(m):
    out["events"].append(m)
    print("[p6]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"), timeout=t)


async def write(cl, frame):
    await cl.write_gatt_char(WRITE, frame, response=False)


def last(cmd, since):
    r = [d for t, c, d in rx if c == cmd and t >= since]
    return r[-1] if r else None


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
            out["frames"].append({"t": round(time.monotonic() - t0, 2), "cmd": (f.cmd if f.crc_ok else None), "data": (f.data.hex() if f.crc_ok else b.hex())})

        def on4(_s, data):
            file_chunks.append(bytes(data))

        async with BleakClient(dev) as cl:
            await asyncio.sleep(0.3)
            await cl.start_notify(B2, on2)
            await cl.start_notify(B4, on4)
            await write(cl, C.bind(CODE)); await asyncio.sleep(1.5)
            ev(f"绑定={ (last(0x03,0) or b'').hex() }")
            await write(cl, build_frame(0x15)); await asyncio.sleep(1.5)
            r15 = last(0x15, 0)
            fname0 = None
            if r15 and r15[:1] == b"\x00" and len(r15) >= 15:
                fname0 = r15[1:15].split(b"\x00", 1)[0]
            ev(f"0x15={ (r15 or b'').hex() } 录音文件名={fname0!r}")
            ev("再录 5 秒...")
            await asyncio.sleep(5.0)
            tstop = time.monotonic() - t0
            await write(cl, C.stop_recording())
            ev("已发 0x07 停录,轮询 0x0a 等落盘(最多 16s)...")
            fname = None
            for k in range(8):
                await asyncio.sleep(2.0)
                await write(cl, C.list_files())
                await asyncio.sleep(0.6)
                # 找列表条目
                for t, c, d in rx:
                    if c == 0x0A and t >= tstop and d and d[0] == 0x00 and len(d) >= 15:
                        fname = d[1:15].split(b"\x00", 1)[0]; break
                r07 = last(0x07, tstop)
                ev(f"  轮询{k+1}: 0x07回={ (r07 or b'').hex() or '无' } 0x0a条目={fname!r}")
                if fname:
                    break
            target = fname or fname0
            if target:
                ev(f"下载目标文件名={target!r}")
                file_chunks.clear()
                tdl = time.monotonic() - t0
                await write(cl, C.get_file(target.decode("ascii", "replace"), 0))
                await asyncio.sleep(1.0)
                ev(f"0x0b 回={ (last(0x0B, tdl) or b'').hex() or '无' };收 B0B4 12s...")
                await asyncio.sleep(12.0)
                await write(cl, build_frame(0x0C))
                blob = b"".join(file_chunks)
                if blob:
                    open(DL, "wb").write(blob)
                    out["download"] = {"name": target.decode("ascii", "replace"), "bytes": len(blob), "chunks": len(file_chunks), "head_hex": blob[:16].hex()}
                    ev(f"✅ 下载 {len(blob)} 字节 / {len(file_chunks)} 分片")
                else:
                    out["download"] = {"name": target.decode("ascii", "replace"), "bytes": 0, "note": "B0B4 无数据"}
                    ev("❌ B0B4 无数据")
            else:
                ev("仍拿不到文件名(列表空 & 0x15 无名)")
            ev(f"末态 connected={cl.is_connected} elapsed={round(time.monotonic()-t0,1)}s")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev(f"写出 {OUT}")


asyncio.run(main())
