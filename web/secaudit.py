"""绑定安全审计:在已绑(183396)的真机 A7 上验证两个问题——
  A) 已绑状态下，用一个不同的"陌生"码改绑(0x03 op0x00)是否被接受? (=陌生人能否抢绑)
  B) 用一个"错误"码解绑(0x03 op0x01)是否生效?                 (=陌生人能否清绑)
每步用 0x02 取绑定信息核对真实状态。无论结果如何，最后强制恢复到 183396。

只发 0x03(绑定/解绑) 与 0x02(读绑定信息)；绝不碰破坏性命令(0x10/0x12/0x0d)，录音数据不受影响。
轻度破坏性：会临时改动绑定状态，结束自动复原。eddie 已授权(2026-06-18)。
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
WRITE, B2 = U(0xB0B1), U(0xB0B2)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/secaudit_out.json"

REAL = b"183396"    # 真实(官方)配对码
REBIND = b"270900"  # 改绑测试用的"陌生"码(不等于 REAL)
WRONG = b"000000"   # 解绑测试用的"错误"码(不等于任何已绑码)

out = {"events": [], "steps": [], "final_bind": None}
rx = []  # [(t, cmd, data)]
t0 = 0.0


def ev(m):
    out["events"].append(m)
    print("[sec]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"),
        timeout=t,
    )


async def req(cl, label, frame, expect_cmd, wait=1.8):
    """发一帧、等 expect_cmd 回包，返回回包 data(bytes) 或 None。"""
    send_t = time.monotonic() - t0
    try:
        await cl.write_gatt_char(WRITE, frame, response=False)
    except Exception as e:
        ev(f"{label}: 写失败 {e!r}")
        return None
    end = time.monotonic() + wait
    while time.monotonic() < end:
        for tt, c, d in rx:
            if c == expect_cmd and tt >= send_t:
                return d
        await asyncio.sleep(0.05)
    return None


def binfo(d):
    if d is None:
        return "(无回复)"
    if all(b == 0 for b in d):
        return "<全0=未绑定>"
    return d.split(b"\x00", 1)[0].decode("ascii", "replace")


def verdict(r):
    if r is None:
        return "(无回复)"
    if r and r[0] == 0x00:
        return "接受(00)"
    if r and r[0] == 0x01:
        return "拒绝(01)"
    return f"其它({r.hex()})"


async def session(dev, do):
    """建立连接、订阅 B2、清空 rx、重置 t0，然后执行 do(cl)。"""
    global t0
    rx.clear()
    t0 = time.monotonic()
    async with BleakClient(dev) as cl:
        def on_b2(_s, data):
            b = bytes(data)
            f = parse_frame(b)
            rx.append((time.monotonic() - t0, f.cmd if f.crc_ok else -1, f.data if f.crc_ok else b))
        await asyncio.sleep(0.3)
        await cl.start_notify(B2, on_b2)
        return await do(cl)


async def experiment(cl):
    # 0. 基线绑定 183396（稳住连接，必须在 5s 内）
    r = await req(cl, "基线绑定 0x03(183396)", C.bind(REAL, 0x00), 0x03, wait=2.5)
    ev(f"基线绑定: {verdict(r)}")
    # 1. 基线 0x02
    b0 = await req(cl, "基线 0x02", C.get_bind_info(), 0x02)
    ev(f"基线绑定信息(0x02) = {binfo(b0)}")
    out["steps"].append({"k": "baseline", "bindinfo": binfo(b0), "raw": b0.hex() if b0 else None})

    # 2. TEST A：已绑下用陌生码 270900 改绑
    ra = await req(cl, "TEST A 改绑 0x03(270900,op0)", C.bind(REBIND, 0x00), 0x03, wait=2.0)
    ba = await req(cl, "A 后 0x02", C.get_bind_info(), 0x02)
    ev(f"【A 改绑】设备回包={verdict(ra)}; 改绑后 0x02={binfo(ba)}")
    out["steps"].append({"k": "A_rebind_stranger", "reply": verdict(ra), "bindinfo_after": binfo(ba)})

    # 3. TEST B：用错误码 000000 解绑
    rb = await req(cl, "TEST B 解绑 0x03(000000,op1)", C.bind(WRONG, 0x01), 0x03, wait=2.0)
    bb = await req(cl, "B 后 0x02", C.get_bind_info(), 0x02)
    ev(f"【B 解绑】设备回包={verdict(rb)}; 解绑后 0x02={binfo(bb)}")
    out["steps"].append({"k": "B_unbind_wrongcode", "reply": verdict(rb), "bindinfo_after": binfo(bb)})

    # 4. 复原到 183396
    rr = await req(cl, "复原绑定 0x03(183396,op0)", C.bind(REAL, 0x00), 0x03, wait=2.0)
    bf = await req(cl, "复原后 0x02", C.get_bind_info(), 0x02)
    ev(f"复原: {verdict(rr)}; 复原后 0x02={binfo(bf)}")
    out["final_bind"] = binfo(bf)
    return binfo(bf)


async def restore_only(cl):
    rr = await req(cl, "二次复原 0x03(183396)", C.bind(REAL, 0x00), 0x03, wait=2.5)
    bf = await req(cl, "二次复原后 0x02", C.get_bind_info(), 0x02)
    ev(f"二次复原: {verdict(rr)}; 0x02={binfo(bf)}")
    out["final_bind"] = binfo(bf)
    return binfo(bf)


async def main():
    try:
        os.remove(OUT)
    except OSError:
        pass

    ev("扫描设备……请现在反复按录音笔按键唤醒(每 1~2 秒按一下)")
    dev = await find(45.0)
    if not dev:
        ev("没找到设备(没醒?再点按键并重跑 web/secaudit.py)")
        json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
        return
    ev(f"找到 {dev.address}，连接 + 跑实验……")

    final = None
    try:
        final = await session(dev, experiment)
    except Exception as e:
        ev(f"主会话异常 {e!r}")

    # 强制确保复原:若最终不是 183396，再单独连最多 2 次复原
    attempt = 0
    while final != "183396" and attempt < 2:
        attempt += 1
        ev(f"final={final}，二次确保复原(第{attempt}次)……请再按按键唤醒")
        dev2 = await find(30.0)
        if not dev2:
            ev("复原重连:没找到设备")
            continue
        try:
            final = await session(dev2, restore_only)
        except Exception as e:
            ev(f"复原会话异常 {e!r}")

    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    ev(f"=== 完成。final_bind={out['final_bind']} (期望 183396) ===")


asyncio.run(main())
