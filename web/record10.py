"""录制质量测试:录一段干净的 10 秒并完整下载。

连上→绑定→(若在录先停掉清场)→0x06 开录→精确录 10s→0x07 停录(拿文件名+大小)
→0x0b 取文件→循环收 B0B4 直到累计达到文件大小→0x0c 停→存 rec10.mp3。
"""

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
OUT = "/Users/eddie/Desktop/proj/Hospital/web/record10_out.json"
MP3 = "/Users/eddie/Desktop/proj/Hospital/web/rec10.mp3"
DONE = "/tmp/a7_record10_done"
CODE = b"183396"
REC_SECONDS = 10.0

out = {"events": [], "download": None}
rx = []
file_chunks = []
t0 = 0.0


def ev(m):
    out["events"].append(m)
    print("[rec10]", m, flush=True)


async def find(t):
    return await BleakScanner.find_device_by_filter(
        lambda d, ad: (COMPANY_ID in (ad.manufacturer_data or {})) or (d.name == "X Note"), timeout=t)


async def send_wait(cl, cmd, frame, wait=3.0):
    st = time.monotonic() - t0
    await cl.write_gatt_char(WRITE, frame, response=False)
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if any(c == cmd and t >= st for t, c, _ in rx):
            break
        await asyncio.sleep(0.05)
    reps = [d for t, c, d in rx if c == cmd and t >= st]
    return reps[-1] if reps else None


def parse_name_size(reply):
    # reply = 00 + name14 + size4(大端) + type ...
    if reply and reply[:1] == b"\x00" and len(reply) >= 19:
        name = reply[1:15].split(b"\x00", 1)[0]
        size = int.from_bytes(reply[15:19], "big")
        return name, size
    return None, 0


async def main():
    global t0
    for p in (DONE, OUT, MP3):
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

        def on4(_s, data):
            file_chunks.append(bytes(data))

        async with BleakClient(dev) as cl:
            await asyncio.sleep(0.3)
            await cl.start_notify(B2, on2)
            await cl.start_notify(B4, on4)

            bind = await send_wait(cl, 0x03, C.bind(CODE), 2.5)
            ev(f"绑定={ (bind or b'').hex() }")

            # 清场:若在录音,先停掉
            r15 = await send_wait(cl, 0x15, build_frame(0x15), 2.0)
            if r15 and r15[:1] == b"\x00":
                ev("当前在录音,先停掉清场...")
                await send_wait(cl, 0x07, C.stop_recording(), 4.0)
                await asyncio.sleep(1.0)

            # 开录(设备自分配文件名)
            start = await send_wait(cl, 0x06, C.start_recording("QUALITY10", 1), 3.0)
            ev(f"开录 0x06={ (start or b'').hex() }")
            ev(f"精确录 {REC_SECONDS} 秒(请保持设备旁有声音,比如正常说话)...")
            await asyncio.sleep(REC_SECONDS)

            stop = await send_wait(cl, 0x07, C.stop_recording(), 5.0)
            ev(f"停录 0x07={ (stop or b'').hex() }")
            name, size = parse_name_size(stop)
            if not name:
                # 退而求其次:从开录回复拿名字,列表拿大小
                n2, _ = parse_name_size(start)
                name = n2
                lst = await send_wait(cl, 0x0A, C.list_files(), 3.0)
                n3, s3 = parse_name_size(lst)
                if n3:
                    name, size = n3, s3
            ev(f"目标文件: name={name!r} size={size}B (≈{round(size/4000,1)}s @32kbps)")

            if name:
                file_chunks.clear()
                gf = await send_wait(cl, 0x0B, C.get_file(name.decode("ascii", "replace"), 0), 3.0)
                n4, s4 = parse_name_size(b"\x00" + b"\x00" * 14 + (gf[1:5] if gf and len(gf) >= 5 else b"\x00\x00\x00\x00"))
                target = size or (int.from_bytes(gf[1:5], "big") if gf and len(gf) >= 5 else 0)
                ev(f"0x0b={ (gf or b'').hex() };目标大小={target}B,循环收 B0B4...")
                deadline = time.monotonic() + 30
                last_n = -1
                stable = 0
                while time.monotonic() < deadline:
                    n = sum(len(c) for c in file_chunks)
                    if target and n >= target:
                        ev(f"已收满 {n}/{target}B")
                        break
                    if n == last_n:
                        stable += 1
                        if stable >= 15 and n > 0:  # 3s 没新增,认为结束
                            ev(f"收取停滞于 {n}B,结束")
                            break
                    else:
                        stable = 0
                        last_n = n
                    await asyncio.sleep(0.2)
                await send_wait(cl, 0x0C, build_frame(0x0C), 2.0)
                blob = b"".join(file_chunks)
                # 裁到首个 MP3 同步
                s = next((k for k in range(min(len(blob), 4000) - 1) if blob[k] == 0xFF and (blob[k + 1] & 0xE0) == 0xE0), 0)
                open(MP3, "wb").write(blob[s:])
                out["download"] = {"name": name.decode("ascii", "replace"), "reported_size": size, "got_bytes": len(blob), "chunks": len(file_chunks), "head": blob[:16].hex()}
                ev(f"✅ 存 rec10.mp3:{len(blob)}B / {len(file_chunks)}分片(裁{s}B到同步)")
            else:
                ev("拿不到文件名")
            ev(f"末态 connected={cl.is_connected} elapsed={round(time.monotonic()-t0,1)}s")
    json.dump(out, open(OUT, "w"), ensure_ascii=False, indent=0)
    open(DONE, "w").write("done")
    ev(f"写出 {OUT}")


asyncio.run(main())
