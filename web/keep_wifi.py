"""开新机 Soft AP 热点并一直保持,直到 Ctrl+C。
用法:  cd /Users/eddie/Desktop/proj/Hospital && .venv/bin/python3 web/keep_wifi.py
连上后:SSID = Doway_<SN后4位>,密码 = <SN前8位>,网关 http://192.168.200.1/get_files
"""
import asyncio, sys
sys.path.insert(0, "/Users/eddie/Desktop/proj/Hospital")
from bleak import BleakScanner, BleakClient
from a7ble.framing import build_frame, parse_frame
from a7ble.advert import parse_from_bleak

SN = "Q95HA00078"   # 目标新机 SN 前缀


def pr(b): return "".join(chr(x) if 32 <= x < 127 else "." for x in b)


async def find(t=25):
    f = asyncio.get_event_loop().create_future()
    def cb(d, ad):
        if f.done(): return
        a = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        if a and a.sn.startswith(SN): f.set_result(d)
    s = BleakScanner(detection_callback=cb); await s.start()
    try: return await asyncio.wait_for(f, t)
    finally: await s.stop()


async def main():
    print(f"扫蓝牙找新机({SN})… 请确保它醒着、手机 App 没连它")
    try:
        dev = await find()
    except asyncio.TimeoutError:
        print("✗ 没扫到。按一下机身键唤醒,或断开手机对它的连接,再重跑。"); return
    print(f"✓ 已连 {dev.name}")

    async with BleakClient(dev) as cli:
        m = {}
        for s in cli.services:
            for c in s.characteristics:
                m[c.uuid.split('-')[0][-4:]] = c

        def on_rx(_h, d):
            f = parse_frame(bytes(d))
            if f.crc_ok and f.cmd == 0x1b:
                print(f"  [设备] openWifi 回应 = {f.data.hex()}  (00=成功)")
        await cli.start_notify(m["b0b2"], on_rx)

        async def w(cmd, pl=b""):
            await cli.write_gatt_char(m["b0b1"], build_frame(cmd, pl), response=False)
            await asyncio.sleep(0.8)

        # 复刻官方序列:绑定 → 设备信息 → 文件列表 → 开热点
        await w(0x03, "183396".encode().ljust(16, b"\x00") + b"\x00")
        await w(0x05)
        await w(0x0a)
        await cli.write_gatt_char(m["b0b1"], build_frame(0x1b, b"\x01"), response=False)

        print("\n" + "=" * 56)
        print("★ 热点已开,正在保持(按 Ctrl+C 结束)")
        print("  Wi-Fi 名 : Doway_0078")
        print("  密码     : Q95HA000")
        print("  连上后访问: http://192.168.200.1/get_files")
        print("  ⚠️ 手机记得【关掉移动数据】,否则请求会绕到蜂窝网打不到设备")
        print("=" * 56 + "\n")

        try:
            while True:
                if cli.is_connected:
                    try:
                        await cli.write_gatt_char(m["b0b1"], build_frame(0x05), response=False)  # 保活
                    except Exception:
                        print("  (BLE 写失败,可能断连)")
                else:
                    print("  ✗ BLE 已断,热点可能即将关闭,请重跑"); break
                await asyncio.sleep(3)
        except KeyboardInterrupt:
            print("\n收到 Ctrl+C,关闭。")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
