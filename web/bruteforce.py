"""聚焦暴力:一次连接内快速轰 ~50 个候选配对码(0x01),找能绑定的那个。

依据实测:错码不会立即断连,设备对每个 0x01 都回 SN(FA9HA00685);~8s 未绑定才断。
所以可在窗口内连发候选。命中信号:1) 连接撑过 ~13s(基线 ~8s 必断);2) 冒出"非 SN"回包。
候选都是 SN 的确定性变换 / 常见固定码 —— 真 16B 密钥无法暴力,这轮只赌"简单方案"。
eddie 已授权试探(2026-06-17)。
"""

import asyncio
import hashlib
import json
import os
import sys
import time
import zlib

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakClient, BleakScanner  # noqa: E402
from a7ble import commands as C  # noqa: E402
from a7ble.advert import COMPANY_ID  # noqa: E402
from a7ble.crc import crc16_arc  # noqa: E402

U = lambda x: f"0000{x:04x}-0000-1000-8000-00805f9b34fb"
WRITE, CMD = U(0xB0B1), U(0xB0B2)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/brute_out.json"
DONE = "/tmp/a7_brute_done"
SN = b"FA9HA00685"
SN_HEX = SN.hex()  # 46413948413030363835


def candidates():
    out, seen = [], set()

    def add(name, code):
        if isinstance(code, str):
            code = code.encode()
        code = code[:16]
        if code not in seen:
            seen.add(code)
            out.append((name, code))

    add("sn", SN)
    add("sn_rev", SN[::-1])
    add("sn_lower", SN.lower())
    add("num00685", "00685")
    add("num685", "685")
    add("685_le", (685).to_bytes(4, "little"))
    add("123792", "123792")
    add("123792_le32", (123792).to_bytes(4, "little"))
    add("123792_be32", (123792).to_bytes(4, "big"))
    add("zeros", b"\x00" * 16)
    add("ffs", b"\xff" * 16)
    add("incr", bytes(range(16)))
    for pin in ["0000", "1234", "8888", "6666", "1111", "123456", "000000", "888888", "666666", "520520", "112233", "147258"]:
        add("pin_" + pin, pin)
    for w in ["zhixin", "ZX", "doway", "Doway", "DOWAY", "xink", "XINK", "xink_test", "admin", "BLE", "FA9HA"]:
        add("w_" + w, w)
    add("md5_raw16", hashlib.md5(SN).digest())
    add("md5_hex16", hashlib.md5(SN).hexdigest()[:16].encode())
    add("sha1_16", hashlib.sha1(SN).digest()[:16])
    add("sha256_16", hashlib.sha256(SN).digest()[:16])
    c16 = crc16_arc(SN)
    add("crc16_le", c16.to_bytes(2, "little"))
    add("crc16_be", c16.to_bytes(2, "big"))
    c32 = zlib.crc32(SN) & 0xFFFFFFFF
    add("crc32_le", c32.to_bytes(4, "little"))
    add("crc32_be", c32.to_bytes(4, "big"))
    add("crc32_hex", format(c32, "08x").encode())
    add("mac", bytes.fromhex("50c0f03331e1"))
    add("mac_str", "50c0f03331e1")
    add("sn_xorff", bytes(b ^ 0xFF for b in SN))
    return out


out = {"events": [], "sends": [], "replies": [], "nonSN": [], "held": False}


def ev(m):
    out["events"].append(m)
    print("[brute]", m, flush=True)


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
    cands = candidates()
    ev(f"候选 {len(cands)} 个;扫描设备(请点一下按键唤醒)")
    dev = await find(45.0)
    if not dev:
        ev("没找到设备(睡了?点按键重来)")
    else:
        t0 = time.monotonic()

        def on(_s, data):
            h = bytes(data).hex()
            t = round(time.monotonic() - t0, 3)
            out["replies"].append({"t": t, "hex": h})
            if SN_HEX not in h:  # 不是 SN 回显 = 可能绑定成功的不同回包
                out["nonSN"].append({"t": t, "hex": h})
                print(f"   !! 非SN回包 t={t} {h}", flush=True)

        try:
            async with BleakClient(dev) as cl:
                await asyncio.sleep(0.3)
                try:
                    await cl.start_notify(CMD, on)
                except Exception as e:
                    ev(f"notify err {e!r}")
                await cl.write_gatt_char(WRITE, C.bind(b""), response=False)  # 先探一次拿 SN
                await asyncio.sleep(0.5)
                ev("开始 blast 候选码")
                for name, code in cands:
                    out["sends"].append({"t": round(time.monotonic() - t0, 3), "name": name, "code": code.hex()})
                    try:
                        await cl.write_gatt_char(WRITE, C.bind(code), response=False)
                    except Exception as e:
                        ev(f"写 {name} 失败 {e!r}")
                        break
                    await asyncio.sleep(0.07)
                ev("blast 完毕,监控连接")
                for _ in range(34):
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
