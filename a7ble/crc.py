"""CRC-16/ARC (poly 0x8005 / 反射 0xA001, 初值 0, refin/refout=true)。

协议帧的校验算法。校验范围 = 帧头至 data 全部;结果以大端 2 字节附在帧尾。
"""


def crc16_arc(data: bytes) -> int:
    crc = 0x0000
    for b in data:
        crc ^= b
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc & 0xFFFF
