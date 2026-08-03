"""A7 录音笔 BLE 客户端 CLI。

里程碑:
  scan    M0 扫描列出设备(标出疑似 A7 / 0x1116 厂商号)
  probe   M0 连接并 dump 所有 GATT service/characteristic —— 决定协议是否适用 A7
  info    M1 发 0x05 读设备信息(冒烟成功线)
  send    通用: 发任意 cmd+data,抓所有 notify(从零逆向的主力工具)
  ls      M2 发 0x0a 文件列表,尝试解析条目
  pull    M2 发 0x0b 取文件,B0B4 负载落地
  stream  M3 发 0x06 开录,B0B3 实时流落地

UUID 是逆向猜测;先跑 `probe` 看真值,再用 --write-uuid / --cmd-uuid 等覆盖。
"""

from __future__ import annotations

import argparse
import asyncio
from typing import List

from . import commands as C
from . import transport as T
from .framing import parse_frame


def _short(uuid: str) -> str:
    # 0000b0b2-0000-1000-8000-00805f9b34fb -> b0b2
    parts = uuid.split("-")
    return parts[0][-4:] if parts else uuid


def _dump_packets(packets: List[T.Packet]) -> None:
    if not packets:
        print("  (无 notify —— 设备可能未唤醒/未连上/UUID 不对/无回包)")
        return
    for p in packets:
        line = f"  [{p.t:6.3f}s] {_short(p.char)}  {p.data.hex(' ')}"
        f = parse_frame(p.data)
        if f.crc_ok:
            line += f"   <frame cmd=0x{f.cmd:02x} len={len(f.data)} crc_ok>"
        print(line)


async def _cmd_scan(args) -> None:
    print(f"扫描 {args.timeout}s ...(设备无连接会秒睡,先按一下设备按键唤醒)")
    hits = await T.scan(args.timeout)
    if not hits:
        print("没扫到任何 BLE 设备。")
        return
    for h in hits:
        flag = ""
        if h.adv is not None:
            flag = f"  <<< 0x{h.adv.company_id:04x} MAC={h.adv.mac} SN={h.adv.sn}"
        mfr = ",".join(f"0x{k:04x}" for k in h.manufacturer_data) or "-"
        print(f"{h.rssi:4d}dBm  {h.address}  {h.name or '(无名)':<20} mfr=[{mfr}]{flag}")
    print("\n提示: 带 <<< 的是 0x1116 厂商号(协议描述的格式);若 A7 不在其中,按名字/RSSI 认出 A7 后用它的地址跑 probe。")


async def _cmd_probe(args) -> None:
    print(f"连接 {args.address} 并枚举 GATT ...")
    svcs = await T.probe(args.address)
    for s in svcs:
        print(f"\nSERVICE {s['uuid']}  {s['description'] or ''}")
        for c in s["chars"]:
            print(f"  CHAR {c['uuid']}  [{','.join(c['properties'])}]  {c['description'] or ''}")
    print("\n对照协议: 找控制服务(应含 1 写 + 3 notify)与 OTA(Nordic DFU)。")
    print("把这里的真实 UUID 填进后续命令的 --write-uuid / --cmd-uuid 等即可。")


async def _cmd_info(args) -> None:
    print(f"M1: 发 0x05 设备信息 -> {args.address}")
    pkts = await T.run_command(
        args.address, C.get_device_info(), listen=args.listen,
        write_uuid=args.write_uuid, notify_uuids=[args.cmd_uuid],
    )
    _dump_packets(pkts)
    for p in pkts:
        f = parse_frame(p.data)
        if f.crc_ok and f.cmd == C.CMD_DEVICE_INFO:
            di = C.decode_device_info(f.data)
            print(f"\n设备信息原始 {di.length}B: {di.raw.hex(' ')}")
            print("(30B 字段布局待验证 —— 把这段贴给我,我来逐字段反推)")
            return


async def _cmd_send(args) -> None:
    from .framing import build_frame
    data = bytes.fromhex(args.data) if args.data else b""
    frame = build_frame(args.cmd, data)
    print(f"发 cmd=0x{args.cmd:02x} data={data.hex(' ') or '(空)'} -> {args.address}")
    pkts = await T.run_command(
        args.address, frame, listen=args.listen,
        write_uuid=args.write_uuid, notify_uuids=args.notify or list(T.ALL_NOTIFY),
    )
    _dump_packets(pkts)


async def _cmd_capture(args) -> None:
    seq = [
        ("0x05 device_info", C.get_device_info(), 1.5),
        ("0x03 get_sn", C.get_sn(), 1.5),
        ("0x0a file_list", C.list_files(), 2.0),
    ]
    print(f"批量抓取(单连接,发 device_info + SN + file_list) -> {args.address}")
    packets, marks = await T.capture(
        args.address, seq, settle=args.settle, write_uuid=args.write_uuid,
    )
    events = [("mark", t, lbl) for t, lbl in marks] + [("pkt", p.t, p) for p in packets]
    events.sort(key=lambda e: e[1])
    if not events:
        print("  (无任何事件 —— 设备没醒/没连上;按一下按键再重跑)")
        return
    for kind, t, obj in events:
        if kind == "mark":
            print(f"  [{t:6.3f}s] >>> 发送 {obj}")
        else:
            f = parse_frame(obj.data)
            tag = f"cmd=0x{f.cmd:02x} crc_ok" if f.crc_ok else "raw"
            print(f"  [{t:6.3f}s] {_short(obj.char)}  {obj.data.hex(' ')}  <{tag}>")
    print("\n把以上整段贴给我即可。")


async def _cmd_ls(args) -> None:
    print(f"M2: 发 0x0a 文件列表 -> {args.address}")
    pkts = await T.run_command(
        args.address, C.list_files(), listen=args.listen,
        write_uuid=args.write_uuid, notify_uuids=[args.cmd_uuid],
    )
    _dump_packets(pkts)
    print("\n尝试按 (name14+size4+type1) 解析条目(布局待验证):")
    for p in pkts:
        f = parse_frame(p.data)
        if f.crc_ok and f.cmd == C.CMD_FILE_LIST and len(f.data) >= C.NAME_LEN + 5:
            e = C.decode_file_list_entry(f.data[1:] if len(f.data) % 19 else f.data)
            print(f"  name={e.name!r} size={e.size} type={e.type}")


async def _cmd_pull(args) -> None:
    print(f"M2: 发 0x0b 取文件 {args.name!r} -> {args.address}")
    pkts = await T.run_command(
        args.address, C.get_file(args.name, args.seek), listen=args.listen,
        write_uuid=args.write_uuid, notify_uuids=[args.file_uuid],
    )
    payload = b"".join(p.data for p in pkts if p.char == args.file_uuid)
    if payload:
        with open(args.out, "wb") as fh:
            fh.write(payload)
        print(f"收到 {len(pkts)} 个分片,共 {len(payload)}B -> 落地 {args.out}")
        print("(分片是否含头部/序号、是否需逐块 ack —— 待真机字节确认)")
    else:
        _dump_packets(pkts)


async def _cmd_stream(args) -> None:
    print(f"M3: 发 0x06 开录 {args.name!r} type={args.type}, 收 {args.seconds}s 实时流 -> {args.address}")
    pkts = await T.run_command(
        args.address, C.start_recording(args.name, args.type), listen=args.seconds,
        write_uuid=args.write_uuid, notify_uuids=[args.rt_uuid],
    )
    payload = b"".join(p.data for p in pkts if p.char == args.rt_uuid)
    if payload:
        with open(args.out, "wb") as fh:
            fh.write(payload)
        print(f"收到 {len(pkts)} 个实时分片,共 {len(payload)}B -> 落地 {args.out}")
        print("(A7 标称 Opus/WAV,这里先存裸字节;真实编码看头部魔数再定容器)")
    else:
        _dump_packets(pkts)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="a7ble", description="A7 录音笔 BLE 客户端")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("scan", help="M0 扫描设备")
    s.add_argument("--timeout", type=float, default=8.0)
    s.set_defaults(func=_cmd_scan)

    s = sub.add_parser("probe", help="M0 连接并 dump GATT")
    s.add_argument("--address", required=True)
    s.set_defaults(func=_cmd_probe)

    def add_common(sp):
        sp.add_argument("--address", required=True)
        sp.add_argument("--write-uuid", default=T.CHAR_WRITE)
        sp.add_argument("--listen", type=float, default=3.0)

    s = sub.add_parser("info", help="M1 读设备信息 0x05")
    add_common(s)
    s.add_argument("--cmd-uuid", default=T.CHAR_NOTIFY_CMD)
    s.set_defaults(func=_cmd_info)

    s = sub.add_parser("send", help="通用: 发任意 cmd+data 抓 notify")
    add_common(s)
    s.add_argument("--cmd", required=True, type=lambda x: int(x, 0))
    s.add_argument("--data", default="", help="hex, 如 0a1b2c")
    s.add_argument("--notify", action="append", help="可重复指定要订阅的 char uuid")
    s.set_defaults(func=_cmd_send)

    s = sub.add_parser("capture", help="单连接批量抓取 device_info+SN+file_list(少按键)")
    s.add_argument("--address", required=True)
    s.add_argument("--write-uuid", default=T.CHAR_WRITE)
    s.add_argument("--settle", type=float, default=3.0)
    s.set_defaults(func=_cmd_capture)

    s = sub.add_parser("ls", help="M2 文件列表 0x0a")
    add_common(s)
    s.add_argument("--cmd-uuid", default=T.CHAR_NOTIFY_CMD)
    s.set_defaults(func=_cmd_ls)

    s = sub.add_parser("pull", help="M2 取文件 0x0b -> B0B4")
    add_common(s)
    s.add_argument("--name", required=True)
    s.add_argument("--seek", type=int, default=0)
    s.add_argument("--file-uuid", default=T.CHAR_NOTIFY_FILE)
    s.add_argument("--out", required=True)
    s.set_defaults(func=_cmd_pull)

    s = sub.add_parser("stream", help="M3 实时录音 0x06 -> B0B3")
    s.add_argument("--address", required=True)
    s.add_argument("--write-uuid", default=T.CHAR_WRITE)
    s.add_argument("--name", required=True)
    s.add_argument("--type", type=int, default=0)
    s.add_argument("--seconds", type=float, default=10.0)
    s.add_argument("--rt-uuid", default=T.CHAR_NOTIFY_RT)
    s.add_argument("--out", required=True)
    s.set_defaults(func=_cmd_stream)

    return p


def main(argv=None) -> None:
    args = build_parser().parse_args(argv)
    asyncio.run(args.func(args))


if __name__ == "__main__":
    main()
