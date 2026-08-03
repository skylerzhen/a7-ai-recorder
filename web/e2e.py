"""端到端全量测试:一次绑定连接里跑遍命令,出 PASS/FAIL 报告 + 验证文件下载。

安全策略:破坏性命令(0x10格式化/0x12恢复出厂/0x0d删除)不自动跑,仅标注跳过;
设置类命令回填"当前值"(测通路不改配置);录音用 暂停→恢复、最后 停录下载→重新开录 尽量复原。
绑定成功后连接长保持,故可从容跑完整套。eddie 授权"全功能测试"(2026-06-17)。
"""

import asyncio
import datetime
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
WRITE, B2, B3, B4 = U(0xB0B1), U(0xB0B2), U(0xB0B3), U(0xB0B4)
OUT = "/Users/eddie/Desktop/proj/Hospital/web/e2e_out.json"
DONE = "/tmp/a7_e2e_done"
DL = "/Users/eddie/Desktop/proj/Hospital/web/downloaded.bin"
CODE = b"183396"

out = {"events": [], "results": [], "device_info": None, "download": None}
rx = []          # [(t, cmd, data)] from b0b2
file_chunks = []
t0 = 0.0


def ev(m):
    out["events"].append(m)
    print("[e2e]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"),
        timeout=t,
    )


async def step(cl, label, cmd, frame, ok_pred=None, wait=2.0, collect_all=False):
    """发一帧、等回包、判定 PASS/FAIL。ok_pred(data)->bool;默认有回包即通。"""
    send_t = time.monotonic() - t0
    try:
        await cl.write_gatt_char(WRITE, frame, response=False)
    except Exception as e:
        out["results"].append({"label": label, "cmd": f"0x{cmd:02x}", "ok": False, "detail": f"写失败 {e!r}"})
        ev(f"❌ {label}: 写失败 {e!r}")
        return None
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if any(c == cmd and t >= send_t for t, c, _ in rx):
            if not collect_all:
                break
        await asyncio.sleep(0.05)
    replies = [d for t, c, d in rx if c == cmd and t >= send_t]
    data = replies[-1] if replies else None
    if collect_all:
        data_all = replies
    ok = data is not None
    if ok and ok_pred is not None:
        ok = ok_pred(data)
    detail = (b" | ".join(r for r in replies).hex() if collect_all else (data.hex() if data is not None else "(无回复)"))
    out["results"].append({"label": label, "cmd": f"0x{cmd:02x}", "ok": bool(ok), "detail": detail[:120]})
    ev(f"{'✅' if ok else '❌'} {label}: {detail[:70]}")
    return replies if collect_all else data


def succ(d):  # 设置类:回包 data[0]==0x00 视为成功
    return d is not None and len(d) >= 1 and d[0] == 0x00


async def main():
    global t0
    for p in (DONE, OUT, DL):
        try:
            os.remove(p)
        except OSError:
            pass
    ev("扫描设备(点按键唤醒)")
    dev = await find(45.0)
    if not dev:
        ev("没找到设备")
        return
    t0 = time.monotonic()

    def on_b2(_s, data):
        b = bytes(data)
        f = parse_frame(b)
        rx.append((time.monotonic() - t0, f.cmd if f.crc_ok else -1, f.data if f.crc_ok else b))

    def on_b4(_s, data):
        file_chunks.append(bytes(data))

    async with BleakClient(dev) as cl:
        await asyncio.sleep(0.3)
        for u, cb in [(B2, on_b2), (B4, on_b4)]:
            try:
                await cl.start_notify(u, cb)
            except Exception as e:
                ev(f"notify err {e!r}")

        # ── 1. 绑定(前置,必须成功)──
        bind = await step(cl, "绑定 0x03 (183396)", 0x03, C.bind(CODE), ok_pred=succ, wait=2.5)
        if not succ(bind):
            ev("绑定失败,终止(后续命令都需绑定)")
        else:
            # ── 2. 只读命令 ──
            await step(cl, "取SN 0x01", 0x01, C.get_sn())
            await step(cl, "取绑定信息 0x02", 0x02, C.get_bind_info())
            di = await step(cl, "设备信息 0x05", 0x05, C.get_device_info())
            cur = C.decode_device_info(di) if di else None
            if cur:
                out["device_info"] = {
                    "total_mb": cur.total_mb, "free_mb": cur.free_mb, "charging": cur.charging,
                    "battery": cur.battery, "recording": cur.recording, "model": cur.model,
                    "denoise": cur.denoise, "segment": cur.segment, "screen": cur.backlight,
                    "usb_support": cur.usb_support, "voice": cur.voice_ctrl, "led": cur.led,
                }
            await step(cl, "录音信息 0x15", 0x15, build_frame(0x15))

            # ── 3. 设置类(回填当前值,不改配置;0xFF=不支持则跳过)──
            await step(cl, "设手机类型 0x18=0(安卓)", 0x18, build_frame(0x18, bytes([0])), ok_pred=succ)
            now = datetime.datetime.now()
            await step(cl, "设时间 0x04=现在", 0x04, build_frame(0x04, bytes([now.year - 2000, now.month, now.day, now.hour, now.minute, now.second])), ok_pred=succ)
            if cur:
                await step(cl, f"设降噪 0x17={cur.denoise}(回填)", 0x17, build_frame(0x17, bytes([cur.denoise])), ok_pred=succ)
                await step(cl, f"设分段 0x16={cur.segment}(回填)", 0x16, build_frame(0x16, bytes([cur.segment])), ok_pred=succ)
                await step(cl, f"设USB 0x13={cur.usb_support}(回填)", 0x13, build_frame(0x13, bytes([cur.usb_support])), ok_pred=succ)
                if cur.backlight != 0xFF:
                    await step(cl, f"设屏幕常亮 0x1a={cur.backlight}(回填)", 0x1A, build_frame(0x1A, bytes([cur.backlight])), ok_pred=succ)
                if cur.led != 0xFF:
                    await step(cl, f"设指示灯 0x11={cur.led}(回填)", 0x11, build_frame(0x11, bytes([cur.led])), ok_pred=succ)
                else:
                    out["results"].append({"label": "指示灯 0x11", "cmd": "0x11", "ok": None, "detail": "设备无此功能(0x05[16]=0xFF),跳过"})
                if cur.voice_ctrl != 0xFF:
                    await step(cl, f"设声控 0x14={cur.voice_ctrl}(回填)", 0x14, build_frame(0x14, bytes([cur.voice_ctrl])), ok_pred=succ)
                else:
                    out["results"].append({"label": "声控 0x14", "cmd": "0x14", "ok": None, "detail": "设备无此功能(0x05[40]=0xFF),跳过"})

            # ── 4. 录音控制:暂停→恢复(原地复原)──
            await step(cl, "暂停录音 0x08", 0x08, C.pause(), ok_pred=succ, wait=2.0)
            await step(cl, "恢复录音 0x09", 0x09, build_frame(0x09), ok_pred=succ, wait=2.0)

            # ── 5. 文件流程:停录→列表→下载→停取 ──
            stop = await step(cl, "停止录音 0x07(落盘)", 0x07, C.stop_recording(), ok_pred=succ, wait=3.0)
            await asyncio.sleep(1.0)
            entries = await step(cl, "文件列表 0x0a", 0x0A, C.list_files(), wait=3.0, collect_all=True)
            fname = None
            if entries:
                for d in entries:
                    if d and d[0] == 0x00 and len(d) >= 15:
                        fname = d[1:15].split(b"\x00", 1)[0]
                        break
            if not fname and stop and len(stop) >= 15 and stop[0] == 0x00:
                fname = stop[1:15].split(b"\x00", 1)[0]
            if fname:
                ev(f"下载文件: {fname!r}")
                file_chunks.clear()
                await step(cl, f"取文件 0x0b ({fname.decode('ascii','replace')})", 0x0B, C.get_file(fname.decode("ascii", "replace"), 0), wait=3.0)
                await asyncio.sleep(6.0)  # 收 B0B4 分片
                await step(cl, "停止取文件 0x0c", 0x0C, build_frame(0x0C), ok_pred=succ, wait=2.0)
                blob = b"".join(file_chunks)
                if blob:
                    open(DL, "wb").write(blob)
                    out["download"] = {"name": fname.decode("ascii", "replace"), "bytes": len(blob), "chunks": len(file_chunks), "head_hex": blob[:16].hex()}
                    ev(f"下载完成: {len(blob)} 字节 / {len(file_chunks)} 分片 → downloaded.bin")
                else:
                    out["download"] = {"name": fname.decode("ascii", "replace"), "bytes": 0, "note": "B0B4 无数据"}
                    ev("下载: B0B4 无数据")
            else:
                ev("没有可下载的已存文件(列表为空)")

            # ── 6. 复原:重新开始录音(并测 0x06)──
            recname = datetime.datetime.now().strftime("%Y%m%d%H%M%S")[:14]
            await step(cl, f"开始录音 0x06 ({recname})", 0x06, C.start_recording(recname, 1), ok_pred=lambda d: len(d) >= 1 and d[0] == 0x00, wait=2.5)

            # ── 7. 破坏性命令:仅标注,不执行 ──
            for c, name in [("0x0d", "删除文件"), ("0x10", "格式化"), ("0x12", "恢复出厂")]:
                out["results"].append({"label": f"{name} {c}", "cmd": c, "ok": None, "detail": "破坏性,e2e 不自动执行(需单独确认)"})

        ev(f"测试结束 elapsed={round(time.monotonic()-t0,1)}s connected={cl.is_connected}")

    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev(f"写出 {OUT}")


asyncio.run(main())
