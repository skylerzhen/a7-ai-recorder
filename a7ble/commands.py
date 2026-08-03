"""应用层命令编解码 (cmd 编号与帧结构已验证; 各 data 字段语义 待真机验证)。

请求编码器较可信(手册/协议图明确);响应解码器对未确认字段保留 raw,不硬编码假设。
"""

from dataclasses import dataclass

from .framing import build_frame

# --- cmd id (逆向协议; 见《AI 录音笔 BLE 协议》第 5 节) ---
# ⚠️ 实测(官方 app HCI 抓包,2026-06-17):手册/协议图把 0x01 与 0x03 写反了!
CMD_GET_SN = 0x01        # 实测:0x01=获取SN(回 10B SN)。手册标 0x03 有误
CMD_BIND_INFO = 0x02
CMD_BIND = 0x03          # 实测:0x03=绑定(data[0-15]=16B配对码 + data[16]=0x00绑定/0x01删)。手册标 0x01 有误
CMD_SET_TIME = 0x04      # 年月日时分秒
CMD_DEVICE_INFO = 0x05   # 回 30B: 容量/电量/充电/录音态/版本/型号/降噪/声控/分段/背光
CMD_START_REC = 0x06     # 文件名(14B)+类型(0/1); 实时数据走 B0B3
CMD_STOP_REC = 0x07
CMD_PAUSE = 0x08
CMD_RESUME = 0x09
CMD_FILE_LIST = 0x0A     # 0x00=条目 / 0x02=结束; 每条 名14+大小4+类型
CMD_GET_FILE = 0x0B      # 文件名+seek4B -> 数据走 B0B4
CMD_STOP_FILE = 0x0C
CMD_DELETE = 0x0D
CMD_STATUS = 0x0F        # 设备主动上报

NAME_LEN = 14


def _pad_name(name: str) -> bytes:
    raw = name.encode("ascii")
    if len(raw) > NAME_LEN:
        raise ValueError(f"name exceeds {NAME_LEN} bytes: {name!r}")
    return raw + b"\x00" * (NAME_LEN - len(raw))


# --- 请求编码器 ---
def get_device_info() -> bytes:
    return build_frame(CMD_DEVICE_INFO)


def get_sn() -> bytes:
    return build_frame(CMD_GET_SN)


def get_bind_info() -> bytes:
    """0x02 获取绑定信息:回包 data = 已绑的手机号/用户ID,未绑定则全 0。"""
    return build_frame(CMD_BIND_INFO)


def list_files() -> bytes:
    return build_frame(CMD_FILE_LIST)


def get_file(name: str, seek: int = 0) -> bytes:
    # seek 端序 待验证(暂按小端) — 真机确认后再定
    return build_frame(CMD_GET_FILE, _pad_name(name) + seek.to_bytes(4, "little"))


def start_recording(name: str, type_: int) -> bytes:
    return build_frame(CMD_START_REC, _pad_name(name) + bytes([type_ & 0xFF]))


def stop_recording() -> bytes:
    return build_frame(CMD_STOP_REC)


def pause() -> bytes:
    return build_frame(CMD_PAUSE)


def resume() -> bytes:
    return build_frame(CMD_RESUME)


def bind(code: bytes, op: int = 0x00) -> bytes:
    """0x03 绑定(实测): data = 配对码(16B,不足补0) + op(0x00 绑定/0x01 删除)。
    官方 app 用的码 = "183396"(补零)。注:本固件 0x03=绑定、0x01=取SN(与手册相反)。"""
    if len(code) > 16:
        raise ValueError("bind code exceeds 16 bytes")
    return build_frame(CMD_BIND, code.ljust(16, b"\x00") + bytes([op & 0xFF]))


# --- 响应解码器 ---
@dataclass
class FileEntry:
    name: str
    size: int
    type: int
    raw: bytes


def decode_file_list_entry(entry: bytes) -> FileEntry:
    # 手册 J: name(14) + size(4,大端) + type(1)。0x0a 回包的首字节 status(0x00/0x01/0x02)由调用方剥离。
    # (大小端与设备信息容量一致取大端;待真机绑定后拿到真实条目最终核实)
    name = entry[:NAME_LEN].split(b"\x00", 1)[0].decode("ascii", errors="replace")
    size = int.from_bytes(entry[NAME_LEN:NAME_LEN + 4], "big")
    type_ = entry[NAME_LEN + 4] if len(entry) > NAME_LEN + 4 else -1
    return FileEntry(name=name, size=size, type=type_, raw=bytes(entry))


@dataclass
class DeviceInfo:
    total_mb: int       # [0:4] 大端,单位 MB
    free_mb: int        # [4:8] 大端,单位 MB
    charging: int       # [8] 0未充 1充电中 2充满
    battery: int        # [9] 0-100
    recording: int      # [10] 0未录 1录音中 2暂停
    version: str        # [11:14]
    usb_support: int    # [14]
    mode: int           # [15] 1普通 2电话
    led: int            # [16] 0关 1开 0xFF无
    model: str          # [17:38] 字符串
    poweroff_min: int   # [38]
    denoise: int        # [39] 0关-16最大
    voice_ctrl: int     # [40] 0关 1开 0xFF无
    segment: int        # [41] 0:30m 1:1h 2:2h 3:3h
    backlight: int      # [42]
    usb_state: int      # [43] 0未连 1连接中
    raw: bytes


def decode_device_info(data: bytes) -> DeviceInfo:
    """按厂商手册 E 节解 0x05 设备信息(实测真机 A7 'X Note' 吻合,52B,容量大端)。"""
    g = lambda i: data[i] if i < len(data) else 0
    be = lambda a, b: int.from_bytes(data[a:b], "big") if len(data) >= b else 0
    v = data[11:14]
    return DeviceInfo(
        total_mb=be(0, 4), free_mb=be(4, 8), charging=g(8), battery=g(9),
        recording=g(10),
        version=".".join(str(v[i]) if i < len(v) else "0" for i in range(3)),
        usb_support=g(14), mode=g(15), led=g(16),
        model=data[17:38].split(b"\x00", 1)[0].decode("ascii", errors="replace"),
        poweroff_min=g(38), denoise=g(39), voice_ctrl=g(40), segment=g(41),
        backlight=g(42), usb_state=g(43), raw=bytes(data),
    )
