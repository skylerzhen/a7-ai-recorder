/**
 * 一条 /stream WebSocket 连接的会话:近实时字幕。
 *
 * 复用 XfyunRtasrClient(长连 + keepalive,不会被讯飞 15s 掐断)。
 * 客户端持续发音频二进制(A7 B0B3 是 MP3 分片)→ **流式**喂 ffmpeg(MP3→PCM s16le/16k/mono,
 * 边收边解,绝不攒整段)→ 跨片留余数切 1280B 帧 → RTASR.sendAudio → onTranscript JSON 推回。
 * 按到达节奏转发(B0B3≈实时,不会触发 AI-1 的 4 倍速限流)。
 */

import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { WebSocket } from 'ws'
import OpusScript from 'opusscript'

import { XfyunRtasrClient } from './xfyun-rtasr'
import { speakerLabel } from './transcript'
import type { ProcessConfig } from './process'

const FRAME = 1280

/** 找首个 MP3 帧同步(0xFF + 次字节高 3 bit 全 1);镜像 a7_protocol 的 trimToMp3Sync 判据。 */
export function mp3SyncOffset(buf: Buffer): number {
  for (let i = 0; i + 1 < buf.length; i++) {
    if (buf[i] === 0xff && (buf[i + 1] & 0xe0) === 0xe0) return i
  }
  return -1
}

export class StreamSession {
  private ff: ChildProcessWithoutNullStreams | null = null
  private rtasr: XfyunRtasrClient | null = null
  private remainder: Buffer = Buffer.alloc(0)
  private closed = false
  private frameCount = 0
  private synced = false // 首批字节是否已裁到帧同步
  private preBuf: Buffer = Buffer.alloc(0)
  private opusDec: OpusScript | null = null // opus 模式(新机)解码器
  private opusBuf: Buffer = Buffer.alloc(0) // 跨片攒 88B 记录

  // format: 'mp3'(A7 旧机 B0B3,走 ffmpeg)| 'pcm'(手机麦克风,已是 s16le/16k/mono)| 'opus'(A7 新机 88B 记录,libopus 解)
  constructor(private ws: WebSocket, private cfg: ProcessConfig, private format: 'mp3' | 'pcm' | 'opus' = 'mp3') {}

  private send(obj: unknown): void {
    if (this.ws.readyState === WebSocket.OPEN) {
      try {
        this.ws.send(JSON.stringify(obj))
      } catch {
        /* ignore */
      }
    }
  }

  async start(): Promise<void> {
    // ① 讯飞 RTASR 长连
    const client = new XfyunRtasrClient(this.cfg.xfyun)
    this.rtasr = client
    client.onTranscript = (text, speaker, isFinal, name, startMs, endMs) => {
      this.send({
        type: 'transcript',
        text,
        speaker: name || speakerLabel(speaker),
        isFinal,
        startMs,
        endMs,
      })
    }
    client.onStatus = (status, detail) => this.send({ type: 'status', status, detail })

    let ok = await client.connect()
    if (!ok && !this.closed) {
      // 瞬时 ECONNRESET / 网络抖动 → 短延迟后重试一次
      await new Promise((r) => setTimeout(r, 600))
      ok = await client.connect()
    }
    if (!ok) {
      this.send({ type: 'error', error: '讯飞 RTASR 连接失败(检查 key / 网络)' })
      this.close()
      return
    }

    // ② mp3 模式:ffmpeg 流式 MP3→PCM(边收边解);pcm 模式:手机端已是 s16le/16k/mono,跳过 ffmpeg。
    if (this.format === 'mp3') {
      const ff = spawn('ffmpeg', [
        '-hide_banner', '-loglevel', 'error',
        '-fflags', '+nobuffer',
        '-f', 'mp3', // 强制 MP3 解复用,不靠格式探测(真机中间帧起步不再刷 Header missing)
        '-i', 'pipe:0',
        '-f', 's16le', '-ar', '16000', '-ac', '1',
        '-flush_packets', '1',
        'pipe:1',
      ])
      this.ff = ff
      ff.stdout.on('data', (pcm: Buffer) => this.onPcm(pcm))
      ff.stderr.on('data', (d: Buffer) => {
        const s = d.toString().trim()
        if (s) console.warn('[stream ffmpeg]', s.slice(0, 200))
      })
      ff.on('error', (e) => this.send({ type: 'error', error: `ffmpeg: ${e.message}` }))
      ff.stdin.on('error', () => {/* 客户端早断时忽略 EPIPE */})
    }

    if (this.format === 'opus') {
      this.opusDec = new OpusScript(16000, 1) // SILK-WB / 16k / mono
    }

    this.send({ type: 'ready' })
  }

  /** 客户端发来的音频。pcm 模式:已是 s16le/16k/mono,直接切帧;mp3 模式:喂 ffmpeg(首批裁到帧同步)。 */
  onAudio(chunk: Buffer): void {
    if (this.closed) return
    if (this.format === 'pcm') {
      this.onPcm(chunk) // 复用 1280B 帧切分 + rtasr.sendAudio
      return
    }
    if (this.format === 'opus') {
      this.onOpus(chunk)
      return
    }
    if (!this.ff) return
    if (!this.synced) {
      // 真机 B0B3 可能从帧中间起步:攒到首个帧同步,裁掉前导再下喂。
      this.preBuf = this.preBuf.length ? Buffer.concat([this.preBuf, chunk]) : chunk
      const off = mp3SyncOffset(this.preBuf)
      if (off >= 0) {
        this.synced = true
        const head = this.preBuf.subarray(off)
        this.preBuf = Buffer.alloc(0)
        try { this.ff.stdin.write(head) } catch {/* ignore */}
      } else if (this.preBuf.length > 16384) {
        // 16KB 仍无同步(异常):直接喂,交 ffmpeg 自行 resync。
        try { this.ff.stdin.write(this.preBuf) } catch {/* ignore */}
        this.preBuf = Buffer.alloc(0)
        this.synced = true
      }
      return
    }
    try {
      this.ff.stdin.write(chunk)
    } catch {
      /* ignore */
    }
  }

  private onPcm(pcm: Buffer): void {
    this.remainder = this.remainder.length ? Buffer.concat([this.remainder, pcm]) : pcm
    while (this.remainder.length >= FRAME) {
      const frame = Buffer.from(this.remainder.subarray(0, FRAME)) // 拷贝,避免视图被覆盖
      this.remainder = this.remainder.subarray(FRAME)
      this.rtasr?.sendAudio(frame)
      this.frameCount++
    }
  }

  /** opus 模式(新机):88B 记录流 → 取 [8:88] 80B 包 → libopus 解 PCM16 → 复用 onPcm 切 1280B 帧喂 RTASR。 */
  private onOpus(chunk: Buffer): void {
    const dec = this.opusDec
    if (!dec) return
    this.opusBuf = this.opusBuf.length ? Buffer.concat([this.opusBuf, chunk]) : chunk
    while (this.opusBuf.length >= 88) {
      const packet = this.opusBuf.subarray(8, 88) // 跳过 [0:4]len + [4:8]序号
      this.opusBuf = this.opusBuf.subarray(88)
      try {
        const pcm = dec.decode(Buffer.from(packet))
        if (pcm && pcm.length) this.onPcm(pcm)
      } catch {
        /* 坏包跳过(基准实测 0 坏帧) */
      }
    }
  }

  /** 客户端「结束」:冲掉 ffmpeg、补末帧、finish RTASR。 */
  async end(): Promise<void> {
    if (this.closed) return
    const ff = this.ff
    if (ff) {
      try {
        ff.stdin.end()
      } catch {
        /* ignore */
      }
      await new Promise<void>((r) => {
        ff.on('close', () => r())
        setTimeout(r, 4000) // 兜底
      })
    }
    if (this.remainder.length > 0) {
      const f = Buffer.alloc(FRAME)
      this.remainder.copy(f)
      this.rtasr?.sendAudio(f)
      this.remainder = Buffer.alloc(0)
    }
    await this.rtasr?.finish(3000)
    this.send({ type: 'done', frames: this.frameCount })
    this.close()
  }

  close(): void {
    if (this.closed) return
    this.closed = true
    try { this.opusDec?.delete() } catch {/* ignore */}
    this.opusDec = null
    try {
      this.ff?.stdin.end()
    } catch {/* ignore */}
    try {
      this.ff?.kill('SIGKILL')
    } catch {/* ignore */}
    try {
      this.rtasr?.disconnect()
    } catch {/* ignore */}
    try {
      if (this.ws.readyState === WebSocket.OPEN) this.ws.close()
    } catch {/* ignore */}
  }
}
