"""拉新硬件上已存录音文件(0x0b),看文件头魔数判定编码。"""
from __future__ import annotations

import asyncio
import sys
import time

from bleak import BleakScanner, BleakClient

sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from a7ble import commands as C
from a7ble import transport as T
from a7ble.advert import parse_from_bleak
from a7ble.framing import parse_frame

TARGET_SN = "Q95HA00078"


async def find_device(timeout=25.0):
    fut = asyncio.get_event_loop().create_future()

    def cb(device, ad):
        if fut.done():
            return
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if adv and adv.sn.startswith(TARGET_SN):
            fut.set_result(device)

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    try:
        return await asyncio.wait_for(fut, timeout)
    finally:
        await scanner.stop()


def parse_file_list(cmd_pkts):
    files = []
    for _, d in cmd_pkts:
        f = parse_frame(d)
        if not (f.crc_ok and f.cmd == C.CMD_FILE_LIST):
            continue
        data = f.data
        if not data or data[0] != 0x00:  # 0x02=结束
            continue
        entry = data[1:]
        if len(entry) < C.NAME_LEN + 5:
            continue
        e = C.decode_file_list_entry(entry)
        files.append(e)
    return files


async def main():
    print(f"扫描中,请让新设备({TARGET_SN})醒着、别让 App 连它...")
    try:
        device = await find_device()
    except asyncio.TimeoutError:
        print("超时:没扫到目标设备。")
        return
    print(f"找到 {device.name}({device.address}),连接...")

    cmd_pkts = []
    file_bytes = bytearray()
    t0 = time.monotonic()

    def cmd_cb(_s, data):
        cmd_pkts.append((time.monotonic() - t0, bytes(data)))

    def file_cb(_s, data):
        file_bytes.extend(bytes(data))

    async with BleakClient(device) as client:
        await client.start_notify(T.CHAR_NOTIFY_CMD, cmd_cb)   # B0B2
        await client.start_notify(T.CHAR_NOTIFY_FILE, file_cb)  # B0B4

        # 1) 取文件列表
        await client.write_gatt_char(T.CHAR_WRITE, C.list_files(), response=False)
        await asyncio.sleep(2.5)
        files = parse_file_list(cmd_pkts)
        if not files:
            print("没解析到文件列表条目。原始 B0B2:")
            for t, d in cmd_pkts:
                print(f"  [{t:6.3f}s] {d.hex(' ')}")
            return
        files.sort(key=lambda e: e.size)
        print(f"文件列表({len(files)} 个):")
        for e in files:
            print(f"  name={e.name!r}  size={e.size}  type={e.type}")
        target = files[0]  # 拉最小的,快
        print(f"\n>>> 0x0b 拉取最小文件 {target.name!r} ({target.size}B)")

        cmd_pkts.clear()
        await client.write_gatt_char(
            T.CHAR_WRITE, C.get_file(target.name, 0), response=False
        )
        # 收 12s 或够 4KB 即可(只需文件头判编码)
        for _ in range(24):
            await asyncio.sleep(0.5)
            if len(file_bytes) >= 4096:
                break
        try:
            await client.stop_notify(T.CHAR_NOTIFY_FILE)
            await client.stop_notify(T.CHAR_NOTIFY_CMD)
        except Exception:
            pass

    print(f"\n=== 0x0b 期间 B0B2 指令回包 ===")
    for t, d in cmd_pkts:
        f = parse_frame(d)
        tag = f"cmd=0x{f.cmd:02x}" if f.crc_ok else "raw"
        print(f"  [{t:6.3f}s] {d.hex(' ')}  <{tag}>")

    print(f"\n=== B0B4 文件数据:{len(file_bytes)} 字节 ===")
    if not file_bytes:
        print("  (B0B4 没收到数据 —— 取文件可能要先绑定,或文件通道变了)")
        return
    head = bytes(file_bytes[:64])
    print(f"  前 64B hex : {head.hex(' ')}")
    print(f"  前 64B ascii: {''.join(chr(b) if 32<=b<127 else '.' for b in head)}")

    # 魔数判定
    verdict = "未知"
    if head[:3] == b"ID3" or (head[0] == 0xFF and (head[1] & 0xE0) == 0xE0):
        verdict = "MP3"
    elif head[:4] == b"OggS":
        verdict = "Ogg(可能 Opus/Vorbis)"
    elif b"OpusHead" in bytes(file_bytes[:128]):
        verdict = "Opus(裸 OpusHead)"
    elif head[:4] == b"RIFF":
        verdict = "WAV"
    elif head[:4] == b"fLaC":
        verdict = "FLAC"
    elif head[0] == 0xFF and (head[1] & 0xF6) == 0xF0:
        verdict = "ADTS-AAC"
    print(f"\n  >>> 文件头判定: {verdict}")
    with open("/tmp/new_hw_file.bin", "wb") as fh:
        fh.write(file_bytes)
    print("  已存 /tmp/new_hw_file.bin(可进一步 ffmpeg 验证)")


if __name__ == "__main__":
    asyncio.run(main())
