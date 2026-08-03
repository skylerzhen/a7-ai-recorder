"""BLE 完整序列(含 0x0b 选文件)开热点 → Mac 切到 Doway → nmap 全端口扫 + curl → 切回。
查清设备 Wi-Fi 快传到底在哪个端口/什么协议服务文件。
"""
import asyncio, sys, re
sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakScanner, BleakClient
from a7ble.framing import build_frame, parse_frame
from a7ble.advert import parse_from_bleak

SN = "Q95HA00078"
IFACE = "en0"
AP_SSID, AP_PWD = "Doway_0078", "Q95HA000"


async def find(t=25):
    f = asyncio.get_event_loop().create_future()
    def cb(d, ad):
        if f.done(): return
        a = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if a and a.sn.startswith(SN): f.set_result(d)
    s = BleakScanner(detection_callback=cb); await s.start()
    try: return await asyncio.wait_for(f, t)
    finally: await s.stop()


async def sh(*cmd, timeout=30):
    p = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    try:
        out, _ = await asyncio.wait_for(p.communicate(), timeout); return out.decode(errors="replace")
    except asyncio.TimeoutError:
        try: p.kill()
        except Exception: pass
        return "(timeout)"


async def main():
    print(f"① BLE 找新机({SN})… 醒着、手机别连")
    try: dev = await find()
    except asyncio.TimeoutError: print("✗ 没扫到,安全退出(没动 Wi-Fi)"); return
    print(f"✓ 连 {dev.name}")
    files = []

    async with BleakClient(dev) as cli:
        m = {}
        for s in cli.services:
            for c in s.characteristics: m[c.uuid.split('-')[0][-4:]] = c
        def on_rx(_h, d):
            fr = parse_frame(bytes(d))
            if fr.crc_ok and fr.cmd == 0x0a and len(fr.data) >= 15 and fr.data[0] == 0x00:
                name = bytes(fr.data[1:15]).split(b"\x00")[0].decode("ascii", "replace")
                if name and name not in files: files.append(name)
        await cli.start_notify(m["b0b2"], on_rx)
        async def w(cmd, pl=b""):
            await cli.write_gatt_char(m["b0b1"], build_frame(cmd, bytes(pl)), response=False); await asyncio.sleep(1.0)
        await w(0x03, "183396".encode().ljust(16, b"\x00") + b"\x00")
        await w(0x05)
        await w(0x18, b"\x00")   # 官方序列里 0x0a 之前的前置
        await w(0x0a); await asyncio.sleep(2.0)
        print(f"   文件列表: {files[:6]}")
        if files:
            fn = files[0].encode("ascii").ljust(14, b"\x00") + (0).to_bytes(4, "little")
            await w(0x0b, fn)   # 选中第一个文件(复刻官方序列)
            print(f"   已 0x0b 选中 {files[0]}")
        await cli.write_gatt_char(m["b0b1"], build_frame(0x1b, b"\x01"), response=False)
        await asyncio.sleep(1.5)
        print("② openWifi 已发,热点开启")

        stop = {"v": False}
        async def keep():
            while not stop["v"] and cli.is_connected:
                try: await cli.write_gatt_char(m["b0b1"], build_frame(0x05), response=False)
                except Exception: break
                await asyncio.sleep(3)
        ka = asyncio.create_task(keep())

        result = ""
        try:
            print(f"③ Mac 切到 {AP_SSID}…")
            await sh("networksetup", "-setairportnetwork", IFACE, AP_SSID, AP_PWD, timeout=25)
            await asyncio.sleep(6)
            result += "en0 IP = " + (await sh("ipconfig", "getifaddr", IFACE, timeout=8)).strip() + "\n"
            print("   等服务起来(10s)…"); await asyncio.sleep(10)
            print("④ 快速探端口…")
            ports = [80, 8080, 8000, 21, 8021, 5000, 9000, 8888, 443, 8443, 8088, 3000, 18080, 8081, 81, 88, 8090, 50000, 12345]
            openp = []
            for p in ports:
                r = await sh("bash", "-c", f"nc -z -G1 192.168.200.1 {p} >/dev/null 2>&1 && echo Y", timeout=4)
                if "Y" in r: openp.append(p)
            result += f"开放端口: {openp or '无'}\n"
            for p in (openp or [80]):
                for ep in ["/", "/get_files", f"/get_file_info?name={files[0] if files else ''}"]:
                    b = await sh("curl", "-s", "-i", "--max-time", "6", f"http://192.168.200.1:{p}{ep}", timeout=10)
                    result += f"\n==== :{p} GET {ep} ====\n{b[:900]}\n"
        finally:
            stop["v"] = True
            print("⑤ 切回原 Wi-Fi…")
            await sh("networksetup", "-setairportpower", IFACE, "off", timeout=10); await asyncio.sleep(2)
            await sh("networksetup", "-setairportpower", IFACE, "on", timeout=10); await asyncio.sleep(8)
        try: await ka
        except Exception: pass

    print("\n================ 结果 ================\n" + result)


if __name__ == "__main__":
    asyncio.run(main())
