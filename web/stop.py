"""停录:绑定→0x07 停止录音(等落盘回复)→0x05 确认已停。"""

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
WRITE, B2 = U(0xB0B1), U(0xB0B2)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/stop_out.json"
DONE = "/tmp/a7_stop_done"
CODE = b"183396"
out = {"events": [], "stopped_file": None, "still_recording": None}
rx = []
t0 = 0.0


def ev(m):
    out["events"].append(m); print("[stop]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"), timeout=t)


async def sw(cl, cmd, frame, wait=3.0):
    st = time.monotonic() - t0
    await cl.write_gatt_char(WRITE, frame, response=False)
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if any(c == cmd and t >= st for t, c, _ in rx):
            break
        await asyncio.sleep(0.03)
    r = [d for t, c, d in rx if c == cmd and t >= st]
    return r[-1] if r else None


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

        async with BleakClient(dev) as cl:
            await asyncio.sleep(0.3)
            await cl.start_notify(B2, on2)
            ev(f"绑定={ (await sw(cl, 0x03, C.bind(CODE), 2.5) or b'').hex() }")
            ev("发 0x07 停止录音,等落盘...")
            stop = await sw(cl, 0x07, C.stop_recording(), 8.0)
            if stop and stop[:1] == b"\x00" and len(stop) >= 19:
                name = stop[1:15].split(b"\x00", 1)[0].decode("ascii", "replace")
                size = int.from_bytes(stop[15:19], "big")
                out["stopped_file"] = {"name": name, "size": size, "sec": round(size / 4000, 1)}
                ev(f"✅ 已停录,文件={name} 大小={size}B (≈{round(size/4000,1)}s)")
            else:
                ev(f"0x07 回复={ (stop or b'').hex() or '无(可能已停或落盘中)' }")
            # 确认录音态
            await asyncio.sleep(1.0)
            di = await sw(cl, 0x05, C.get_device_info(), 2.5)
            if di:
                d = C.decode_device_info(di)
                out["still_recording"] = bool(d.recording)
                ev(f"复查 0x05: 录音态={'录音中' if d.recording else '已停止(未录音)'} 电量={d.battery}%")
            ev(f"完成 elapsed={round(time.monotonic()-t0,1)}s")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev("写出 stop_out.json")


asyncio.run(main())
