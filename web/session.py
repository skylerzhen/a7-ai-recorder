"""一次性 BLE 会话(由 agent 通过 Terminal 触发,Terminal 有蓝牙权限)。

扫描 X Note -> 连接 -> 发 0x05/0x03/0x0a -> 抓 b0b2/b0b4 回复 -> 记录断连时刻。
故意不订阅 b0b3(实时 MP3),避免噪声与拥塞。结果写 session_out.json,
完成后写 /tmp/a7_session_done 作为哨兵。
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
OUT = "/Users/eddie/Desktop/proj/Hospital/web/session_out.json"
DONE = "/tmp/a7_session_done"

out = {"events": [], "packets": []}


def ev(m):
    out["events"].append({"t": round(time.time(), 3), "m": m})
    print("[a7]", m, flush=True)


async def main():
    for p in (DONE, OUT):
        try:
            os.remove(p)
        except OSError:
            pass
    ev("扫描最多 50s 找 X Note —— 请点一下设备按键唤醒它")
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"),
        timeout=50.0,
    )
    if not dev:
        ev("没找到设备(可能睡了 —— 点按键后我会重试)")
        return
    ev(f"找到 {dev.name} [{dev.address}],连接中...")
    t0 = time.monotonic()

    def cb(src):
        def _(_s, data):
            h = bytes(data).hex()
            out["packets"].append({"t": round(time.monotonic() - t0, 3), "src": src, "hex": h})
            print(f"  RX {src} {h[:56]}", flush=True)
        return _

    try:
        async with BleakClient(dev) as cl:
            ev(f"connected={cl.is_connected}")
            await asyncio.sleep(0.4)
            try:
                ev(f"services={len(list(cl.services))}")
            except Exception as e:
                ev(f"services-access-err: {e!r}")
            for u, name in [(CMD, "b0b2"), (FILE, "b0b4")]:
                try:
                    await cl.start_notify(u, cb(name))
                    ev(f"已订阅 {name}")
                except Exception as e:
                    ev(f"订阅 {name} 失败: {e!r}")
            # 先发最想要的 0x0a/0x03(8s 内拿到),0x05 放后面(已有,且兼当 diff 样本)
            for frame, label in [
                (C.list_files(), "0x0a list"),
                (C.get_sn(), "0x03 sn"),
                (C.get_device_info(), "0x05 info"),
            ]:
                try:
                    await cl.write_gatt_char(WRITE, frame, response=False)
                    ev(f"已发 {label}")
                except Exception as e:
                    ev(f"发 {label} 失败: {e!r}")
                await asyncio.sleep(1.3)
            for _ in range(15):
                if not cl.is_connected:
                    ev(f"设备主动断开 @ ~{round(time.monotonic() - t0, 1)}s")
                    break
                await asyncio.sleep(1.0)
            ev(f"结束 is_connected={cl.is_connected} elapsed={round(time.monotonic() - t0, 1)}s")
    except Exception as e:
        ev(f"会话异常: {e!r}")


asyncio.run(main())
json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
open(DONE, "w").write("done")
print("[a7] 写出", OUT, "packets=", len(out["packets"]), flush=True)
