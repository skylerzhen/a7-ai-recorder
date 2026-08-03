"""试探性绑定:一次唤醒内依次试多个配对码,哪个能让连接撑过 8s 即视为绑定成功。

eddie 已授权试探(2026-06-17)。风险:可能覆盖官方 Doway 配对(多半可重配/出厂重置 0x12 恢复)。
依据信号:1) 连接是否撑过 ~11s(基线 ~8s 必断);2) 0x01 是否回 b0b2;3) 0x0a 是否回出文件条目。
"""

import asyncio
import json
import os
import sys
import time

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakClient, BleakScanner  # noqa: E402
from a7ble import commands as C  # noqa: E402
from a7ble.advert import COMPANY_ID  # noqa: E402

U = lambda x: f"0000{x:04x}-0000-1000-8000-00805f9b34fb"
WRITE, CMD, FILE = U(0xB0B1), U(0xB0B2), U(0xB0B4)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/bind_out.json"
DONE = "/tmp/a7_bind_done"

CANDIDATES = [
    ("ascii-123792", b"123792"),
    ("zeros16", b"\x00" * 16),
    ("sn-FA9HA00685", b"FA9HA00685"),
    ("le32-123792", (123792).to_bytes(4, "little")),
]

out = {"attempts": [], "events": [], "held": False}


def ev(m):
    out["events"].append(m)
    print("[bind]", m, flush=True)


async def find(timeout):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"),
        timeout=timeout,
    )


async def main():
    for p in (DONE, OUT):
        try:
            os.remove(p)
        except OSError:
            pass
    held = False
    for idx, (name, code) in enumerate(CANDIDATES):
        if held:
            break
        ev(f"=== 尝试 #{idx} {name} code={code.hex()} ===")
        dev = await find(14.0 if idx == 0 else 7.0)
        if not dev:
            ev("没找到设备(睡了?需要再点一下按键重来)")
            break
        att = {"name": name, "code_hex": code.hex(), "packets": [], "drop_t": None, "alive_end": False}
        t0 = time.monotonic()

        def cb(src):
            def _(_s, data):
                att["packets"].append({"t": round(time.monotonic() - t0, 3), "src": src, "hex": bytes(data).hex()})
                print(f"   RX {src} {bytes(data).hex()[:56]}", flush=True)
            return _

        try:
            async with BleakClient(dev) as cl:
                await asyncio.sleep(0.3)
                for u, nm in [(CMD, "b0b2"), (FILE, "b0b4")]:
                    try:
                        await cl.start_notify(u, cb(nm))
                    except Exception as e:
                        ev(f"notify {nm} err {e!r}")
                try:
                    await cl.write_gatt_char(WRITE, C.bind(code), response=False)
                    ev("已发 0x01 bind")
                except Exception as e:
                    ev(f"bind 写失败 {e!r}")
                await asyncio.sleep(1.5)
                try:
                    await cl.write_gatt_char(WRITE, C.list_files(), response=False)
                    ev("已发 0x0a list")
                except Exception as e:
                    ev(f"list 写失败 {e!r}")
                for _ in range(24):  # 监控到 ~12s(基线 8s 必断)
                    if not cl.is_connected:
                        att["drop_t"] = round(time.monotonic() - t0, 1)
                        ev(f"断开 @ {att['drop_t']}s")
                        break
                    await asyncio.sleep(0.5)
                if cl.is_connected:
                    att["alive_end"] = True
                    ev(f"连接撑过 {round(time.monotonic()-t0,1)}s —— 该码疑似绑定成功!再取一次文件列表")
                    try:
                        await cl.write_gatt_char(WRITE, C.list_files(), response=False)
                    except Exception:
                        pass
                    await asyncio.sleep(2.0)
                    held = True
        except Exception as e:
            ev(f"会话异常 {e!r}")
        out["attempts"].append(att)
    out["held"] = held
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev(f"写出 {OUT} held={held}")


asyncio.run(main())
