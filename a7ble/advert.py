"""BLE 广播厂商数据解析。

格式(已验证): 厂商号 0x1116(小端 2B) + MAC(6B) + SN(10 ASCII) = 18B
实测例: 1611 50c0f013d4c2 46413948413030363636
       -> 0x1116 / 50:c0:f0:13:d4:c2 / "FA9HA00666"
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

COMPANY_ID = 0x1116


@dataclass
class AdvInfo:
    company_id: int
    mac: str
    sn: str
    raw: bytes


def parse_manufacturer_blob(blob: bytes) -> AdvInfo:
    """blob = 厂商号(2B 小端) + MAC(6B) + SN(10 ASCII)。"""
    company_id = blob[0] | (blob[1] << 8)
    mac = ":".join(f"{b:02x}" for b in blob[2:8])
    sn = blob[8:18].decode("ascii", errors="replace")
    return AdvInfo(company_id=company_id, mac=mac, sn=sn, raw=bytes(blob))


def parse_from_bleak(manufacturer_data: Dict[int, bytes]) -> Optional[AdvInfo]:
    """bleak 的 advertisement_data.manufacturer_data 是 {company_id: payload}。

    payload 已不含厂商号(MAC+SN),这里补回厂商号字节后复用同一解析。
    """
    payload = manufacturer_data.get(COMPANY_ID)
    if payload is None:
        return None
    blob = bytes([COMPANY_ID & 0xFF, (COMPANY_ID >> 8) & 0xFF]) + bytes(payload)
    return parse_manufacturer_blob(blob)
