"""真机抓本地快传 socket 帧:BLE 全序列开热点 → Mac 连 Doway → TCP 192.168.200.1:8475
→ 发 getFiles(10) → 抓 Xnote 帧原始 hex(解开发列的所有待定:端序/cmd偏移/名长/分块)。
"""
import asyncio, sys, struct
sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakScanner, BleakClient
from a7ble.framing import build_frame, parse_frame
from a7ble.advert import parse_from_bleak

SN = "Q95HA00078"
IFACE = "en0"
AP_SSID, AP_PWD = "Doway_0078", "Q95HA000"
HEAD = b"XnoteWifiHead  "   # 15B
TAIL = b"XnoteWifiTail   "  # 16B


def xnote(cmd: int, payload: bytes = b"") -> bytes:
    # head(15) | cmd(1) | 00 00 | 00 00 | int32 len(BE) | payload | tail(16)
    return HEAD + bytes([cmd]) + b"\x00\x00" + b"\x00\x00" + struct.pack(">i", len(payload)) + payload + TAIL


def parse_xnote(buf: bytes):
    out = []
    i = 0
    while True:
        h = buf.find(HEAD, i)
        if h < 0: break
        t = buf.find(TAIL, h + len(HEAD))
        if t < 0: break
        body = buf[h + len(HEAD): t]   # cmd(1)+0000+0000+len(4)+payload
        out.append(body)
        i = t + len(TAIL)
    return out


async def find(t=25):
    f = asyncio.get_event_loop().create_future()
    def cb(d, ad):
        if f.done(): return
        a = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if a and a.sn.startswith(SN): f.set_result(d)
    s = BleakScanner(detection_callback=cb); await s.start()
    try: return await asyncio.wait_for(f, t)
    finally: await s.stop()


async def sh(*cmd, timeout=25):
    p = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try:
        o, _ = await asyncio.wait_for(p.communicate(), timeout); return o.decode(errors="replace")
    except asyncio.TimeoutError:
        try: p.kill()
        except Exception: pass
        return "(timeout)"


async def main():
    print(f"① BLE 找新机({SN})…")
    try: dev = await find()
    except asyncio.TimeoutError: print("✗ 没扫到,安全退出"); return
    print(f"✓ 连 {dev.name}")
    files = []
    async with BleakClient(dev) as cli:
        m = {}
        for s in cli.services:
            for c in s.characteristics: m[c.uuid.split('-')[0][-4:]] = c
        def on_rx(_h, d):
            fr = parse_frame(bytes(d))
            if fr.crc_ok and fr.cmd == 0x0a and len(fr.data) >= 15 and fr.data[0] == 0x00:
                nm = bytes(fr.data[1:15]).split(b"\x00")[0].decode("ascii", "replace")
                if nm and nm not in files: files.append(nm)
        await cli.start_notify(m["b0b2"], on_rx)
        async def w(cmd, pl=b""):
            await cli.write_gatt_char(m["b0b1"], build_frame(cmd, bytes(pl)), response=False); await asyncio.sleep(1.0)
        await w(0x03, "183396".encode().ljust(16, b"\x00") + b"\x00")
        await w(0x05); await w(0x18, b"\x00")
        await w(0x0a); await asyncio.sleep(2.0)
        print(f"   BLE 文件列表: {files[:8]}")
        if files:
            await w(0x0b, files[0].encode("ascii").ljust(14, b"\x00") + (0).to_bytes(4, "little"))
            print(f"   已 0x0b 选中 {files[0]}")
        await cli.write_gatt_char(m["b0b1"], build_frame(0x1b, b"\x01"), response=False)
        await asyncio.sleep(1.5)
        print("② openWifi 已发")

        stop = {"v": False}
        async def keep():
            while not stop["v"] and cli.is_connected:
                try: await cli.write_gatt_char(m["b0b1"], build_frame(0x05), response=False)
                except Exception: break
                await asyncio.sleep(3)
        ka = asyncio.create_task(keep())

        log = ""
        try:
            print(f"③ Mac 连 {AP_SSID}…")
            await sh("networksetup", "-setairportnetwork", IFACE, AP_SSID, AP_PWD, timeout=25)
            await asyncio.sleep(6)
            log += "en0 IP=" + (await sh("ipconfig", "getifaddr", IFACE, timeout=8)).strip() + "\n"
            # TCP 8475,端口起得晚,重试
            reader = writer = None
            for k in range(12):
                try:
                    reader, writer = await asyncio.wait_for(asyncio.open_connection("192.168.200.1", 8475), 3)
                    log += f"④ TCP 8475 连上(第{k+1}次)\n"; break
                except Exception as e:
                    log += f"   8475 try{k+1}: {type(e).__name__}\n"; await asyncio.sleep(1.5)
            if writer:
                req = xnote(10, b"")   # getFiles,空 payload(len=0 端序无关)
                log += f"⑤ 发 getFiles(10): {req.hex(' ')}\n"
                writer.write(req); await writer.drain()
                data = b""
                try:
                    for _ in range(20):
                        chunk = await asyncio.wait_for(reader.read(4096), 2.5)
                        if not chunk: break
                        data += chunk
                        if TAIL in data and len(data) > 40:
                            await asyncio.sleep(0.3)  # 多收一会
                except asyncio.TimeoutError: pass
                log += f"⑥ getFiles 收到 {len(data)} 字节:\n{data[:700].hex(' ')}\n"
                for body in parse_xnote(data):
                    log += f"   <帧> 全 body({len(body)}B)={body[:300].hex(' ')}\n"
                    log += f"        ascii: {''.join(chr(x) if 32<=x<127 else '.' for x in body[:200])}\n"
                # startSyncFile(11):用 BLE 拿到的文件名 + offset 0(BE)
                if files:
                    name = files[0].encode("ascii")
                    req2 = xnote(11, name + struct.pack(">i", 0))
                    log += f"\n⑦ 发 startSyncFile(11) name={files[0]}: {req2.hex(' ')}\n"
                    writer.write(req2); await writer.drain()
                    d2 = b""
                    try:
                        for _ in range(30):
                            ch = await asyncio.wait_for(reader.read(8192), 3)
                            if not ch: break
                            d2 += ch
                            if len(d2) > 20000: break
                    except asyncio.TimeoutError: pass
                    log += f"⑧ startSyncFile 收到 {len(d2)} 字节;前 400B:\n{d2[:400].hex(' ')}\n"
                    log += f"   含 XnoteHead 次数: {d2.count(HEAD[:13])};含 Tail: {d2.count(TAIL[:13])}\n"
                else:
                    log += "\n(BLE 文件列表仍空,跳过 startSyncFile;但 getFiles 帧已抓到)\n"
                try: writer.close()
                except Exception: pass
            else:
                log += "✗ 8475 一直连不上(可能要先真选到文件 / 触发顺序不同)\n"
        finally:
            stop["v"] = True
            await sh("networksetup", "-setairportpower", IFACE, "off", timeout=10); await asyncio.sleep(2)
            await sh("networksetup", "-setairportpower", IFACE, "on", timeout=10); await asyncio.sleep(8)
        try: await ka
        except Exception: pass
    print("\n================ 结果 ================\n" + log)


if __name__ == "__main__":
    asyncio.run(main())
