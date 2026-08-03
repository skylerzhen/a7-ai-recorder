"""真·绑定探针(基于官方 app HCI 抓包破解):0x03 绑定 + 码 "183396"。

实测:0x03=绑定(非手册的0x01)、0x01=取SN。官方 app 绑定码="183396"(补零16B)+op0x00。
流程:0x03 绑定 → 0x0a 文件列表 → 0x02 确认已绑 → 监控连接是否撑过 ~8s 基线(撑过=绑定成功)。
"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakClient, BleakScanner  # noqa: E402
from a7ble import commands as C  # noqa: E402
from a7ble.framing import parse_frame  # noqa: E402
from a7ble.advert import COMPANY_ID  # noqa: E402

U = lambda x: f"0000{x:04x}-0000-1000-8000-00805f9b34fb"
WRITE, CMD, FILE = U(0xB0B1), U(0xB0B2), U(0xB0B4)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/probe3_out.json"
DONE = "/tmp/a7_probe3_done"
CODE = (sys.argv[1].encode() if len(sys.argv) > 1 else b"183396")

out = {"events": [], "packets": [], "held": False, "code": CODE.hex()}


def ev(m):
    out["events"].append(m)
    print("[probe3]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"),
        timeout=t,
    )


async def main():
    for p in (DONE, OUT):
        try:
            os.remove(p)
        except OSError:
            pass
    ev(f"扫描设备(点按键唤醒);绑定码={CODE!r}")
    dev = await find(45.0)
    if not dev:
        ev("没找到设备")
    else:
        t0 = time.monotonic()

        def mk(src):
            def _(_s, data):
                b = bytes(data)
                f = parse_frame(b)
                out["packets"].append({"t": round(time.monotonic() - t0, 3), "src": src, "hex": b.hex(),
                                       "cmd": (f.cmd if f.crc_ok else None), "data": (f.data.hex() if f.crc_ok else None)})
                if src == "b0b2":
                    print(f"   RX b0b2 t={round(time.monotonic()-t0,2)} crc_ok={f.crc_ok} cmd=0x{((f.cmd if f.crc_ok else -1)&0xff):02x} {b.hex()[:56]}", flush=True)
            return _

        try:
            async with BleakClient(dev) as cl:
                await asyncio.sleep(0.3)
                for u, s in [(CMD, "b0b2"), (FILE, "b0b4")]:
                    try:
                        await cl.start_notify(u, mk(s))
                    except Exception as e:
                        ev(f"notify {s} err {e!r}")
                await cl.write_gatt_char(WRITE, C.bind(CODE), response=False)
                ev(f"已发 0x03 绑定 (code={CODE!r})")
                await asyncio.sleep(1.3)
                await cl.write_gatt_char(WRITE, C.list_files(), response=False)
                ev("已发 0x0a 文件列表")
                await asyncio.sleep(1.8)
                await cl.write_gatt_char(WRITE, C.get_bind_info(), response=False)
                ev("已发 0x02 确认绑定状态")
                await asyncio.sleep(1.2)
                for _ in range(20):
                    if not cl.is_connected:
                        ev(f"断开 @ {round(time.monotonic() - t0, 1)}s")
                        break
                    await asyncio.sleep(0.5)
                out["held"] = cl.is_connected and (time.monotonic() - t0) >= 13
                ev(f"末态 connected={cl.is_connected} elapsed={round(time.monotonic() - t0, 1)}s held={out['held']}")
        except Exception as e:
            ev(f"异常 {e!r}")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev(f"写出 {OUT}")


asyncio.run(main())
