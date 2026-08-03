"""完整下载新机最新录音(Wi-Fi 快传 socket)→ 还原 Opus 文件 → 解码 WAV。
BLE 列表取最新文件 → openWifi → TCP8475 → startSyncFile 全量收 → 拼文件 → libopus 解码。
"""
import asyncio, sys, struct, ctypes.util
sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakScanner, BleakClient
from a7ble.framing import build_frame, parse_frame
from a7ble.advert import parse_from_bleak

SN = "Q95HA00078"; IFACE = "en0"; AP_SSID, AP_PWD = "Doway_0078", "Q95HA000"
HEAD = b"XnoteWifiHead  "   # 15B
TAIL = b"XnoteWifiTail   "  # 16B

def xnote(cmd, payload=b""):
    return HEAD + bytes([cmd]) + b"\x00\x00\x00\x00" + struct.pack(">i", len(payload)) + payload + TAIL

def parse_frames(buf):
    """确定性切帧:head(15)|cmd(1)|rsv(2)|rsv(2)|len(4BE)|payload|tail(16)。返回 [(cmd,payload)], 剩余。"""
    out = []; i = 0
    while True:
        h = buf.find(HEAD, i)
        if h < 0: break
        b = h + 15
        if b + 9 > len(buf): break
        cmd = buf[b]; ln = struct.unpack(">i", buf[b+5:b+9])[0]
        end = b + 9 + ln + 16
        if end > len(buf): break          # 帧没收全
        out.append((cmd, buf[b+9:b+9+ln])); i = end
    return out, buf[i:]

async def find(t=25):
    f = asyncio.get_event_loop().create_future()
    def cb(d, ad):
        if f.done(): return
        a = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if a and a.sn.startswith(SN): f.set_result(d)
    s = BleakScanner(detection_callback=cb); await s.start()
    try: return await asyncio.wait_for(f, t)
    finally: await s.stop()

async def sh(*c, timeout=25):
    p = await asyncio.create_subprocess_exec(*c, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try: o,_ = await asyncio.wait_for(p.communicate(), timeout); return o.decode(errors="replace")
    except asyncio.TimeoutError:
        try: p.kill()
        except Exception: pass
        return "(timeout)"

async def main():
    print(f"① BLE 找新机…")
    try: dev = await find()
    except asyncio.TimeoutError: print("✗ 没扫到"); return
    files = []
    async with BleakClient(dev) as cli:
        m = {}
        for s in cli.services:
            for c in s.characteristics: m[c.uuid.split('-')[0][-4:]] = c
        def on_rx(_h, d):
            fr = parse_frame(bytes(d))
            if fr.crc_ok and fr.cmd == 0x0a and len(fr.data) >= 15 and fr.data[0] == 0x00:
                nm = bytes(fr.data[1:15]).split(b"\x00")[0].decode("ascii","replace")
                if nm and nm not in files: files.append(nm)
        await cli.start_notify(m["b0b2"], on_rx)
        async def w(cmd, pl=b""):
            await cli.write_gatt_char(m["b0b1"], build_frame(cmd, bytes(pl)), response=False); await asyncio.sleep(1.0)
        await w(0x03, "183396".encode().ljust(16,b"\x00")+b"\x00"); await w(0x05); await w(0x18,b"\x00")
        await w(0x0a); await asyncio.sleep(2.0)
        print(f"   文件: {files}")
        if not files: print("✗ 卡上没文件,先在设备录一段"); return
        target = files[-1]  # 最新一条
        await w(0x0b, target.encode().ljust(14,b"\x00")+(0).to_bytes(4,"little"))
        await cli.write_gatt_char(m["b0b1"], build_frame(0x1b, b"\x01"), response=False); await asyncio.sleep(1.5)
        print(f"② openWifi;目标文件 {target}")
        stop={"v":False}
        async def keep():
            while not stop["v"] and cli.is_connected:
                try: await cli.write_gatt_char(m["b0b1"], build_frame(0x05), response=False)
                except Exception: break
                await asyncio.sleep(3)
        ka=asyncio.create_task(keep())
        rawfile=b""; size=None
        try:
            await sh("networksetup","-setairportnetwork",IFACE,AP_SSID,AP_PWD,timeout=25); await asyncio.sleep(6)
            reader=writer=None
            for k in range(12):
                try: reader,writer=await asyncio.wait_for(asyncio.open_connection("192.168.200.1",8475),3); break
                except Exception: await asyncio.sleep(1.5)
            if not writer: print("✗ 8475 连不上"); return
            writer.write(xnote(10,b"")); await writer.drain(); await asyncio.sleep(0.5)
            writer.write(xnote(11, target.encode()+struct.pack(">i",0))); await writer.drain()
            print("③ 下载中…")
            buf=b""
            while True:
                try: ch=await asyncio.wait_for(reader.read(16384),4)
                except asyncio.TimeoutError: break
                if not ch: break
                buf+=ch
                frames,buf=parse_frames(buf)
                for cmd,pl in frames:
                    if cmd==0x0b:
                        if size is None and len(pl)==5:    # 首帧 status+size
                            size=struct.unpack(">i",pl[1:5])[0]; print(f"   文件大小={size}")
                        else:
                            rawfile+=pl
                if size and len(rawfile)>=size: break
            writer.write(xnote(12,b"")); await writer.drain()
            try: writer.close()
            except Exception: pass
        finally:
            stop["v"]=True
            await sh("networksetup","-setairportpower",IFACE,"off",timeout=10); await asyncio.sleep(2)
            await sh("networksetup","-setairportpower",IFACE,"on",timeout=10); await asyncio.sleep(8)
        try: await ka
        except Exception: pass
    if size: rawfile=rawfile[:size]
    open("/tmp/dl_new.opusraw","wb").write(rawfile)
    print(f"④ 下载完成 {len(rawfile)}/{size} 字节 → /tmp/dl_new.opusraw")
    # 解码:88B 记录,[8:88]=80B opus,16k mono
    orig=ctypes.util.find_library
    ctypes.util.find_library=lambda n:("/opt/homebrew/lib/libopus.dylib" if n=="opus" else orig(n))
    import opuslib, wave
    dec=opuslib.Decoder(16000,1); pcm=bytearray(); off=0; ok=0
    while off+88<=len(rawfile):
        try: pcm+=dec.decode(bytes(rawfile[off+8:off+88]),320); ok+=1
        except Exception: pass
        off+=88
    with wave.open("/tmp/dl_new.wav","wb") as wv:
        wv.setnchannels(1); wv.setsampwidth(2); wv.setframerate(16000); wv.writeframes(bytes(pcm))
    print(f"⑤ 解码 {ok} 帧 → {len(pcm)/2/16000:.1f}s 音频 → /tmp/dl_new.wav")

if __name__=="__main__":
    asyncio.run(main())
