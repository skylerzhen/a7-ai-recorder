"""只读状态检查:绑定后读 0x05 设备信息 + 0x15 录音信息,报告设备当前在干嘛。不改任何状态。"""

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
OUT = "/Users/eddie/Desktop/proj/Hospital/web/status_out.json"
DONE = "/tmp/a7_status_done"
CODE = b"183396"
out = {"events": [], "device_info": None, "rec_info": None}
rx = []
t0 = 0.0


def ev(m):
    out["events"].append(m); print("[st]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"), timeout=t)


async def sw(cl, cmd, frame, wait=2.5):
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
        ev("没找到设备(它可能没在广播)")
    else:
        t0 = time.monotonic()

        def on2(_s, data):
            b = bytes(data); f = parse_frame(b)
            rx.append((time.monotonic() - t0, f.cmd if f.crc_ok else -1, f.data if f.crc_ok else b))

        async with BleakClient(dev) as cl:
            await asyncio.sleep(0.3)
            await cl.start_notify(B2, on2)
            bind = await sw(cl, 0x03, C.bind(CODE), 2.5)
            ev(f"绑定={ (bind or b'').hex() }")
            di = await sw(cl, 0x05, C.get_device_info(), 2.0)
            if di:
                d = C.decode_device_info(di)
                out["device_info"] = {"charging": d.charging, "battery": d.battery, "recording": d.recording,
                                      "total_mb": d.total_mb, "free_mb": d.free_mb, "model": d.model, "usb_state": d.usb_state}
                chg = {0: "未充电", 1: "充电中", 2: "充满"}.get(d.charging, d.charging)
                rec = {0: "未录音", 1: "录音中", 2: "暂停"}.get(d.recording, d.recording)
                ev(f"0x05: 充电={chg} 电量={d.battery}% 录音态={rec} USB={'连接中' if d.usb_state else '未连接'} 剩余={d.free_mb}/{d.total_mb}MB")
            r15 = await sw(cl, 0x15, build_frame(0x15), 2.0)
            if r15 is not None:
                out["rec_info"] = r15.hex()
                if r15[:1] == b"\x00" and len(r15) >= 19:
                    name = r15[1:15].split(b"\x00", 1)[0].decode("ascii", "replace")
                    size = int.from_bytes(r15[15:19], "big")
                    ev(f"0x15: 正在录音 文件={name} 已录={size}B (≈{round(size/4000,1)}s)")
                else:
                    ev(f"0x15: 当前未在录音 (回 {r15.hex()})")
            ev(f"完成 elapsed={round(time.monotonic()-t0,1)}s")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev("写出 status_out.json")


asyncio.run(main())
