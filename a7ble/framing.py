"""协议帧 build/parse。

帧结构: A0 0A | 01 | CMD | LEN | DATA[LEN] | CRC16(2B 大端)
CRC 校验范围 = 帧头至 data 全部。
"""

from dataclasses import dataclass

from .crc import crc16_arc

HEAD = b"\xA0\x0A"
VERSION = 0x01


@dataclass
class Frame:
    cmd: int
    data: bytes
    crc_ok: bool
    version: int
    raw: bytes


def build_frame(cmd: int, data: bytes = b"") -> bytes:
    if not 0 <= cmd <= 0xFF:
        raise ValueError("cmd out of range 0..255")
    if len(data) > 0xFF:
        raise ValueError("data length exceeds 255")
    body = HEAD + bytes([VERSION, cmd, len(data)]) + data
    crc = crc16_arc(body)
    return body + bytes([crc & 0xFF, (crc >> 8) & 0xFF])  # 小端: 低字节在前(真机实测)


def parse_frame(frame: bytes) -> Frame:
    if len(frame) < 7 or frame[:2] != HEAD:
        return Frame(cmd=-1, data=b"", crc_ok=False, version=-1, raw=bytes(frame))
    version = frame[2]
    cmd = frame[3]
    length = frame[4]
    data = frame[5:5 + length]
    crc_bytes = frame[5 + length:5 + length + 2]
    body = frame[:5 + length]
    crc_ok = (
        len(crc_bytes) == 2
        and crc16_arc(body) == int.from_bytes(crc_bytes, "little")  # 小端
    )
    return Frame(cmd=cmd, data=bytes(data), crc_ok=crc_ok, version=version, raw=bytes(frame))
