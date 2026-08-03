"""解析 btsnoop HCI 日志,抽出 ATT 写/通知(BLE 应用层帧),按时序还原序列。
目标:看官方 Doway App 开 Wi-Fi 快传时,在 b0b1/e606 上按顺序发了哪些帧 + 设备回了什么。
"""
import struct, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "bt_log/honor_bt/bt/btsnoop_hci_20260629_162822.log"

def frame_decode(v: bytes):
    """A0 0A / E5 5E 帧 → (头, cmd, payload) 简述。"""
    if len(v) >= 5 and v[0] in (0xA0, 0xE5) and v[1] in (0x0A, 0x5E):
        head = "A0" if v[0] == 0xA0 else "E5"
        cmd = v[3]; ln = v[4]; payload = v[5:5+ln]
        return f"{head} cmd=0x{cmd:02x} len={ln} payload={payload.hex(' ')}"
    return None

data = open(PATH, "rb").read()
assert data[:8] == b"btsnoop\x00", "不是 btsnoop"
off = 16
# ACL 重组:按 handle 累积,直到 L2CAP 长度收齐
acc = {}  # handle -> (need, buf)
events = []  # (ts, dir, handle, att_opcode, value)
while off + 24 <= len(data):
    olen, ilen, flags, drops, ts = struct.unpack(">IIIIq", data[off:off+24])
    off += 24
    pkt = data[off:off+ilen]; off += ilen
    if not pkt: continue
    htype = pkt[0]
    if htype != 0x02:  # 只看 ACL
        continue
    # flags bit0 (btsnoop): 方向。1=收(device→host),0=发(host→device)
    direction = "RX" if (flags & 0x01) else "TX"
    acl = pkt[1:]
    if len(acl) < 4: continue
    hf, dlen = struct.unpack("<HH", acl[:4])
    handle = hf & 0x0FFF
    pb = (hf >> 12) & 0x3
    body = acl[4:4+dlen]
    if pb == 0x01:  # 续片
        if handle in acc:
            need, buf = acc[handle]; buf += body
            if len(buf) >= need: acc.pop(handle); l2 = buf
            else: acc[handle] = (need, buf); continue
        else: continue
    else:  # 首片
        if len(body) < 4: continue
        l2len, cid = struct.unpack("<HH", body[:4])
        full = body
        if len(full) - 4 < l2len:
            acc[handle] = (l2len + 4, full); continue
        l2 = full
    l2len, cid = struct.unpack("<HH", l2[:4])
    if cid != 0x0004:  # 只看 ATT
        continue
    att = l2[4:4+l2len]
    if not att: continue
    op = att[0]
    # 写命令0x52/写请求0x12/通知0x1b/指示0x1d
    if op in (0x52, 0x12, 0x1b, 0x1d) and len(att) >= 3:
        ah = struct.unpack("<H", att[1:3])[0]
        val = att[3:]
        events.append((ts, direction, ah, op, val))

print(f"共 {len(events)} 条 ATT 写/通知\n")
OPN = {0x52:"WriteCmd", 0x12:"WriteReq", 0x1b:"Notify", 0x1d:"Indicate"}
for ts, d, ah, op, val in events:
    dec = frame_decode(val)
    line = f"[{ts}] {d} h=0x{ah:04x} {OPN.get(op,hex(op)):8s} {val.hex(' ')}"
    if dec: line += f"   << {dec}"
    print(line)
