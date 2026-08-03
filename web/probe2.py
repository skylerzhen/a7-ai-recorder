"""绑定探针(基于手册 C 节:绑定码=手机号/用户ID,0x02 可查已绑 ID)。

流程:0x02 查绑定信息 → 若返回非零 ID 就用它绑、否则按未绑定用默认码 → 0x01 绑定 → 0x0a 文件列表
→ 监控连接是否撑过 ~8s 基线(撑过=绑定成功)。全程日志 b0b2/b0b4。eddie 已授权。
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
OUT = "/Users/eddie/Desktop/proj/Hospital/web/probe2_out.json"
DONE = "/tmp/a7_probe2_done"
DEFAULT_CODE = b"A7CLIENT00000000"  # 未绑定时随便绑一个非零 16B

out = {"events": [], "packets": [], "held": False, "bind_info_data": None, "used_code": None}


def ev(m):
    out["events"].append(m)
    print("[probe2]", m, flush=True)


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
    ev("扫描设备(请点一下按键唤醒)")
    dev = await find(45.0)
    if not dev:
        ev("没找到设备(睡了?点按键重来)")
    else:
        t0 = time.monotonic()
        state = {"bind02": None}

        def on(_s, data):
            b = bytes(data)
            f = parse_frame(b)
            t = round(time.monotonic() - t0, 3)
            out["packets"].append({"t": t, "src": "b0b2", "hex": b.hex(),
                                   "cmd": (f.cmd if f.crc_ok else None),
                                   "data": (f.data.hex() if f.crc_ok else None)})
            print(f"   RX b0b2 t={t} crc_ok={f.crc_ok} cmd=0x{((f.cmd if f.crc_ok else -1)&0xff):02x} {b.hex()[:56]}", flush=True)
            if f.crc_ok and f.cmd == 0x02:
                state["bind02"] = f.data

        def onf(_s, data):
            b = bytes(data)
            t = round(time.monotonic() - t0, 3)
            out["packets"].append({"t": t, "src": "b0b4", "hex": b.hex()})
            print(f"   RX b0b4 t={t} {b.hex()[:56]}", flush=True)

        try:
            async with BleakClient(dev) as cl:
                await asyncio.sleep(0.3)
                for u, cb in [(CMD, on), (FILE, onf)]:
                    try:
                        await cl.start_notify(u, cb)
                    except Exception as e:
                        ev(f"notify err {e!r}")
                await cl.write_gatt_char(WRITE, C.get_bind_info(), response=False)
                ev("已发 0x02 获取绑定信息")
                await asyncio.sleep(1.2)
                bi = state["bind02"]
                out["bind_info_data"] = bi.hex() if bi is not None else None
                if bi and any(bi):
                    code = bi[:16].ljust(16, b"\x00")
                    ev(f"0x02 返回非零 ID,用它绑定: {bi.hex()}")
                else:
                    code = DEFAULT_CODE
                    ev(f"0x02 全0/无回,按未绑定用默认码: {code.hex()}")
                out["used_code"] = code.hex()
                await cl.write_gatt_char(WRITE, C.bind(code), response=False)
                ev("已发 0x01 bind")
                await asyncio.sleep(1.5)
                await cl.write_gatt_char(WRITE, C.list_files(), response=False)
                ev("已发 0x0a 文件列表")
                await asyncio.sleep(2.0)
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
