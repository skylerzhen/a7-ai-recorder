"""Mac BLE 传输适配 (bleak)。

这是硬件边界层,无法离线单测 —— 靠真机验证 (M0 probe)。
所有 notify 原样记录 hex,因为我们在从零逆向,字节就是证据。

UUID 默认值是逆向协议里的短 UUID 猜测;真机以 `probe` 输出为准,
CLI 各命令支持 --write-uuid / --cmd-uuid 等覆盖,不必改代码。
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass
from typing import Dict, List, Optional

from .advert import AdvInfo, parse_from_bleak

# bleak 仅在真正连蓝牙时才需要 —— 延迟到函数内 import,
# 这样协议核心与 CLI --help 无需安装任何依赖即可使用。


def uuid16(x: int) -> str:
    return f"0000{x:04x}-0000-1000-8000-00805f9b34fb"


# 逆向协议里的短 UUID(待真机确认)
SVC_CONTROL = uuid16(0xB0B0)
CHAR_WRITE = uuid16(0xB0B1)          # write-without-response (APP -> Device)
CHAR_NOTIFY_CMD = uuid16(0xB0B2)     # 指令回复
CHAR_NOTIFY_RT = uuid16(0xB0B3)      # 实时录音流
CHAR_NOTIFY_FILE = uuid16(0xB0B4)    # 文件 / 离线数据
ALL_NOTIFY = [CHAR_NOTIFY_CMD, CHAR_NOTIFY_RT, CHAR_NOTIFY_FILE]


@dataclass
class ScanHit:
    address: str
    name: Optional[str]
    rssi: int
    adv: Optional[AdvInfo]
    manufacturer_data: Dict[int, bytes]


@dataclass
class Packet:
    t: float            # 相对起始秒
    char: str           # 来源 characteristic uuid
    data: bytes


async def scan(timeout: float = 8.0) -> List[ScanHit]:
    from bleak import BleakScanner

    hits: Dict[str, ScanHit] = {}

    def cb(device, ad):
        adv = parse_from_bleak(ad.manufacturer_data) if ad.manufacturer_data else None
        hits[device.address] = ScanHit(
            address=device.address,
            name=ad.local_name or device.name,
            rssi=ad.rssi if ad.rssi is not None else 0,
            adv=adv,
            manufacturer_data={k: bytes(v) for k, v in ad.manufacturer_data.items()},
        )

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    await asyncio.sleep(timeout)
    await scanner.stop()
    return sorted(hits.values(), key=lambda h: h.rssi, reverse=True)


async def probe(address: str) -> List[dict]:
    """连接后枚举 GATT services/characteristics —— M0 的核心现实校验。"""
    from bleak import BleakClient

    out: List[dict] = []
    async with BleakClient(address) as client:
        for svc in client.services:
            svc_d = {"uuid": svc.uuid, "description": svc.description, "chars": []}
            for ch in svc.characteristics:
                svc_d["chars"].append(
                    {
                        "uuid": ch.uuid,
                        "properties": list(ch.properties),
                        "description": ch.description,
                    }
                )
            out.append(svc_d)
    return out


async def run_command(
    address: str,
    frame: Optional[bytes],
    listen: float = 3.0,
    write_uuid: str = CHAR_WRITE,
    notify_uuids: Optional[List[str]] = None,
) -> List[Packet]:
    """连接 -> 订阅 notify -> (可选)写一帧 -> 收集 listen 秒内所有 notify。

    frame=None 时只监听(用于纯被动抓 0x0f/0x19 等设备主动上报)。
    缺失的 characteristic 会跳过并告警(因为 UUID 是猜测)。
    """
    from bleak import BleakClient

    notify_uuids = notify_uuids or list(ALL_NOTIFY)
    packets: List[Packet] = []
    t0 = time.monotonic()

    def make_cb(char_uuid: str):
        def _cb(_sender, data: bytearray):
            packets.append(Packet(t=time.monotonic() - t0, char=char_uuid, data=bytes(data)))
        return _cb

    async with BleakClient(address) as client:
        for u in notify_uuids:
            try:
                await client.start_notify(u, make_cb(u))
            except Exception as e:  # UUID 不存在 / 不可 notify
                print(f"[warn] start_notify {u} failed: {e}")
        if frame is not None:
            await client.write_gatt_char(write_uuid, frame, response=False)
        await asyncio.sleep(listen)
        for u in notify_uuids:
            try:
                await client.stop_notify(u)
            except Exception:
                pass
    return packets


async def capture(
    address: str,
    steps,
    settle: float = 3.0,
    write_uuid: str = CHAR_WRITE,
    notify_uuids: Optional[List[str]] = None,
):
    """单连接里按顺序发多帧并全程记录 notify,尽量一次抓全(少按键)。

    steps: 可迭代的 (label:str, frame:bytes, wait_after:float)。
    返回 (packets, marks),marks 是 [(t, label)] 发送时刻标记。
    """
    from bleak import BleakClient

    notify_uuids = notify_uuids or list(ALL_NOTIFY)
    packets: List[Packet] = []
    marks: List = []
    t0 = time.monotonic()

    def make_cb(char_uuid: str):
        def _cb(_sender, data: bytearray):
            packets.append(Packet(t=time.monotonic() - t0, char=char_uuid, data=bytes(data)))
        return _cb

    async with BleakClient(address) as client:
        for u in notify_uuids:
            try:
                await client.start_notify(u, make_cb(u))
            except Exception as e:
                print(f"[warn] start_notify {u} failed: {e}")
        for label, frame, wait in steps:
            marks.append((time.monotonic() - t0, label))
            await client.write_gatt_char(write_uuid, frame, response=False)
            await asyncio.sleep(wait)
        await asyncio.sleep(settle)
        for u in notify_uuids:
            try:
                await client.stop_notify(u)
            except Exception:
                pass
    return packets, marks
