/**
 * XfyunRtasrClient — iFlytek rtasr(大模型版)WebSocket client, **Node 版**。
 *
 * 移植自 web-advisor/src/lib/xfyun-rtasr.ts(浏览器版),仅做平台适配,逻辑(role_type=2
 * 说话人分离、rl→说话人映射、interim/final、keepalive、1280B 帧)与原版一致:
 *   - Web Crypto HMAC-SHA1  → node:crypto createHmac('sha1')
 *   - btoa/TextEncoder/Uint8Array → Buffer
 *   - 浏览器原生 WebSocket → `ws` 包(.on('open'|'message'|'error'|'close'))
 *   - window.setInterval/Timeout → 全局 setInterval/Timeout
 *   - 新增:从 st.bg/st.ed 取 startMs/endMs(原版未用,本棒转写需时间戳)
 */

import { createHmac, randomUUID } from 'node:crypto'
import WebSocket from 'ws'

export interface VoiceprintEntry {
  featureId: string
  name: string
  isMe: boolean
  createdAt: number
}

export interface XfyunConfig {
  appId: string
  accessKeyId: string
  accessKeySecret: string
  voiceprints?: VoiceprintEntry[]
}

export type TranscriptCallback = (
  text: string,
  speaker: 'you' | 'them',
  isFinal: boolean,
  speakerName?: string,
  startMs?: number,
  endMs?: number,
) => void

export interface StatusMeta {
  intentional?: boolean
  recoverable?: boolean
  code?: number
}

export type StatusCallback = (
  status: 'connecting' | 'connected' | 'disconnected' | 'error',
  detail?: string,
  meta?: StatusMeta,
) => void

const FRAME_SIZE = 1280
const KEEPALIVE_INTERVAL_MS = 12_000

export class XfyunRtasrClient {
  private ws: WebSocket | null = null
  private config: XfyunConfig
  private orderedVoiceprints: VoiceprintEntry[]

  // Speaker mapping (ported from XfyunRtasrAdapter.mapRlToSpeaker)
  private currentRl = 0
  private rlToSpeaker = new Map<number, 'you' | 'them'>()
  private rlToName = new Map<number, string>()

  // Keepalive
  private keepAliveInterval: ReturnType<typeof setInterval> | null = null
  private lastAudioSentAt = 0
  private sendCount = 0
  private sessionId = ''
  private finishResolver: (() => void) | null = null
  private connectionGeneration = 0
  private intentionalClose = false
  private fatalClose = false

  // Callbacks
  onTranscript: TranscriptCallback = () => {}
  onStatus: StatusCallback = () => {}

  constructor(config: XfyunConfig) {
    this.config = config
    this.orderedVoiceprints = config.voiceprints ?? []
  }

  async connect(): Promise<boolean> {
    const generation = ++this.connectionGeneration
    this.intentionalClose = false
    this.fatalClose = false
    this.onStatus('connecting')
    this.rlToSpeaker.clear()
    this.rlToName.clear()
    this.currentRl = 0
    this.sendCount = 0
    this.finishResolver = null
    this.sessionId = ''

    if (this.ws && this.ws.readyState !== WebSocket.CLOSED) {
      try {
        this.intentionalClose = true
        this.ws.close()
      } catch { /* ignore */ }
      this.intentionalClose = false
      this.ws = null
    }

    try {
      const url = this.buildAuthUrl()
      console.log(`[XfyunRtasr] Connecting... URL length=${url.length}`)

      return new Promise<boolean>((resolve) => {
        let settled = false
        const settle = (result: boolean) => {
          if (settled) return
          settled = true
          clearTimeout(timeout)
          resolve(result)
        }
        const timeout = setTimeout(() => {
          console.error('[XfyunRtasr] Connection timeout (10s)')
          this.ws?.close()
          this.onStatus('error', 'Connection timeout', { intentional: false, recoverable: true })
          settle(false)
        }, 10_000)

        this.ws = new WebSocket(url)

        this.ws.on('message', (data: WebSocket.RawData) => {
          if (generation !== this.connectionGeneration) return
          try {
            const msg = JSON.parse(data.toString('utf8'))
            this.handleMessage(msg, settle)
          } catch (err) {
            console.error('[XfyunRtasr] Parse error:', err)
          }
        })

        this.ws.on('error', (err: Error) => {
          if (generation !== this.connectionGeneration) return
          console.error('[XfyunRtasr] WebSocket error:', err.message)
          this.finishResolver?.()
          this.finishResolver = null
          this.onStatus('error', `WebSocket error: ${err.message}`, {
            intentional: this.intentionalClose,
            recoverable: !this.intentionalClose && !this.fatalClose,
          })
          settle(false)
        })

        this.ws.on('close', (code: number) => {
          if (generation !== this.connectionGeneration) return
          console.warn(`[XfyunRtasr] WebSocket closed (code=${code}, sends=${this.sendCount})`)
          this.stopKeepalive()
          this.ws = null
          this.finishResolver?.()
          this.finishResolver = null
          this.onStatus('disconnected', `code=${code}`, {
            intentional: this.intentionalClose,
            recoverable: !this.intentionalClose && !this.fatalClose,
            code,
          })
          settle(false)
        })
      })
    } catch (err) {
      console.error('[XfyunRtasr] Connect failed:', err)
      this.onStatus('error', String(err), { intentional: false, recoverable: true })
      return false
    }
  }

  disconnect(): void {
    this.stopKeepalive()
    this.finishResolver = null
    this.intentionalClose = true
    if (this.ws) {
      if (this.ws.readyState === WebSocket.OPEN) {
        try {
          this.ws.send(JSON.stringify({ end: true, sessionId: this.sessionId }))
        } catch { /* ignore */ }
      }
      this.ws.close()
      this.ws = null
    }
  }

  async finish(timeoutMs = 1_500): Promise<void> {
    this.stopKeepalive()
    if (!this.ws) return
    this.intentionalClose = true
    if (this.ws.readyState !== WebSocket.OPEN) {
      try { this.ws.close() } catch { /* ignore */ }
      this.ws = null
      return
    }

    await new Promise<void>((resolve) => {
      let settled = false
      let timer: ReturnType<typeof setTimeout> | null = null
      const finalize = () => {
        if (settled) return
        settled = true
        if (timer) {
          clearTimeout(timer)
        }
        if (this.finishResolver === finalize) {
          this.finishResolver = null
        }
        try { this.ws?.close() } catch { /* ignore */ }
        this.ws = null
        resolve()
      }

      this.finishResolver = finalize
      timer = setTimeout(finalize, timeoutMs)

      try {
        this.ws?.send(JSON.stringify({ end: true, sessionId: this.sessionId }))
      } catch {
        finalize()
      }
    })
  }

  /** Send a 1280-byte PCM frame */
  sendAudio(frame: Buffer): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
    try {
      this.ws.send(frame)
      this.sendCount++
      this.lastAudioSentAt = Date.now()

      if (this.sendCount <= 5 || this.sendCount % 200 === 0) {
        console.debug(`[XfyunRtasr] Send #${this.sendCount}: ${frame.byteLength} bytes`)
      }
    } catch (err) {
      console.error('[XfyunRtasr] Send error:', err)
    }
  }

  // ── Auth URL (node:crypto HMAC-SHA1) ──────────────────────

  private buildAuthUrl(): string {
    const now = new Date()
    const tz = now.getTimezoneOffset()
    const sign = tz <= 0 ? '+' : '-'
    const absH = String(Math.floor(Math.abs(tz) / 60)).padStart(2, '0')
    const absM = String(Math.abs(tz) % 60).padStart(2, '0')
    const pad = (n: number) => String(n).padStart(2, '0')
    const utcStr =
      now.getFullYear() + '-' + pad(now.getMonth() + 1) + '-' + pad(now.getDate()) + 'T' +
      pad(now.getHours()) + ':' + pad(now.getMinutes()) + ':' + pad(now.getSeconds()) +
      sign + absH + absM

    const uuid = randomUUID()

    const params: Record<string, string> = {
      accessKeyId: this.config.accessKeyId,
      appId: this.config.appId,
      audio_encode: 'pcm_s16le',
      lang: 'autodialect',
      role_type: '2',
      samplerate: '16000',
      utc: utcStr,
      uuid,
    }

    // Voiceprint feature IDs
    if (this.orderedVoiceprints.length > 0) {
      params.feature_ids = this.orderedVoiceprints.map(v => v.featureId).join(',')
      console.log(`[XfyunRtasr] Voiceprint feature_ids: ${params.feature_ids}`)
    }

    // Sort keys and build base string
    const sortedKeys = Object.keys(params).sort()
    const baseString = sortedKeys
      .map(k => `${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`)
      .join('&')

    // node:crypto HMAC-SHA1 → base64
    const signature = createHmac('sha1', this.config.accessKeySecret)
      .update(baseString, 'utf8')
      .digest('base64')

    // Build final URL
    const allParams = { ...params, signature }
    const query = Object.entries(allParams)
      .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
      .join('&')

    return `wss://office-api-ast-dx.iflyaisol.com/ast/communicate/v1?${query}`
  }

  // ── Message handling (ported from XfyunRtasrAdapter) ──────

  private handleMessage(
    msg: Record<string, unknown>,
    resolveConnect: (result: boolean) => void
  ): void {
    const msgType = msg.msg_type as string | undefined

    if (msgType === 'action') {
      const data = msg.data as Record<string, unknown> | undefined
      if (data?.action === 'started') {
        this.sessionId = (data.sessionId as string) || ''
        this.lastAudioSentAt = Date.now()
        console.log(`[XfyunRtasr] Handshake OK, sessionId=${this.sessionId}`)
        this.startKeepalive()
        this.onStatus('connected')
        resolveConnect(true)
      }
      return
    }

    if (msgType === 'result') {
      this.handleResult(msg)
      return
    }

    // Error or unknown
    const code = msg.code ?? msg.err_code ?? ''
    const desc = msg.desc ?? msg.message ?? ''
    console.warn(`[XfyunRtasr] Unhandled msg: type=${msgType}, code=${code}, desc=${desc}`)
    if (code) {
      this.fatalClose = true
      this.onStatus('error', `code=${code}${desc ? ` ${desc}` : ''}`, {
        intentional: false,
        recoverable: false,
      })
      try { this.ws?.close() } catch { /* ignore */ }
      resolveConnect(false)
    }
  }

  private handleResult(msg: Record<string, unknown>): void {
    let data = msg.data as Record<string, unknown>
    if (typeof data === 'string') {
      try { data = JSON.parse(data) } catch { return }
    }
    if (!data) return

    const st = (data.cn as Record<string, unknown>)?.st as Record<string, unknown> | undefined
    if (!st) return

    const resultType = st.type as string // "0" = final, "1" = interim
    const isFinal = resultType === '0'
    // 新增:段起止时间(ms),原浏览器版未用
    const startMs = st.bg !== undefined ? Number(st.bg) : undefined
    const endMs = st.ed !== undefined ? Number(st.ed) : undefined
    const rts = st.rt as Array<Record<string, unknown>> | undefined
    if (!rts) return

    let text = ''
    let segmentRl = this.currentRl

    for (const rt of rts) {
      const wsList = rt.ws as Array<Record<string, unknown>> | undefined
      if (!wsList) continue

      for (const ws of wsList) {
        const cwList = ws.cw as Array<Record<string, unknown>> | undefined
        if (!cwList) continue

        for (const cw of cwList) {
          const w = (cw.w as string) || ''
          const wp = (cw.wp as string) || 'n'
          const rlRaw = cw.rl
          const rl = rlRaw !== undefined ? Number(rlRaw) : undefined

          // Track speaker changes (rl comes as string "0" not number 0)
          if (rl !== undefined && rl !== 0) {
            segmentRl = rl
            this.currentRl = rl
          }

          // Skip segment markers
          if (wp === 'g') continue
          text += w
        }
      }
    }

    if (!text.trim()) return

    const { speaker, speakerName } = this.mapRlToSpeaker(segmentRl)
    this.onTranscript(text, speaker, isFinal, speakerName ?? undefined, startMs, endMs)

    // Check last frame
    if (data.ls === true) {
      console.log('[XfyunRtasr] Received last frame (ls=true)')
      this.finishResolver?.()
    }
  }

  /**
   * Map rl value to speaker role.
   * Ported from XfyunRtasrAdapter.mapRlToSpeaker — identical logic.
   */
  private mapRlToSpeaker(rl: number): { speaker: 'you' | 'them'; speakerName: string | null } {
    // rl=0 means continuation
    if (rl === 0) {
      const lastSpeaker = this.rlToSpeaker.get(this.currentRl)
      return {
        speaker: lastSpeaker || 'you',
        speakerName: this.rlToName.get(this.currentRl) || null,
      }
    }

    // First time seeing this non-zero rl
    if (!this.rlToSpeaker.has(rl)) {
      if (this.orderedVoiceprints.length > 0) {
        // Voiceprint mode: rl=N → Nth voiceprint (1-indexed)
        const vpIndex = rl - 1
        if (vpIndex >= 0 && vpIndex < this.orderedVoiceprints.length) {
          const vp = this.orderedVoiceprints[vpIndex]
          this.rlToSpeaker.set(rl, vp.isMe ? 'you' : 'them')
          this.rlToName.set(rl, vp.name)
          console.log(`[XfyunRtasr] Speaker rl=${rl} → voiceprint "${vp.name}" (${vp.isMe ? 'me' : 'other'})`)
        } else {
          this.rlToSpeaker.set(rl, 'them')
        }
      } else {
        // Blind diarization: first speaker = you
        if (this.rlToSpeaker.size === 0) {
          this.rlToSpeaker.set(rl, 'you')
          console.log(`[XfyunRtasr] Speaker rl=${rl} → 'you' (first speaker)`)
        } else {
          this.rlToSpeaker.set(rl, 'them')
          console.log(`[XfyunRtasr] Speaker rl=${rl} → 'them'`)
        }
      }
    }

    return {
      speaker: this.rlToSpeaker.get(rl) || 'them',
      speakerName: this.rlToName.get(rl) || null,
    }
  }

  // ── Keepalive (silent frames to prevent 15s timeout) ──────

  private startKeepalive(): void {
    this.stopKeepalive()
    this.keepAliveInterval = setInterval(() => {
      if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
      const elapsed = Date.now() - this.lastAudioSentAt
      if (elapsed >= KEEPALIVE_INTERVAL_MS) {
        try {
          this.ws.send(Buffer.alloc(FRAME_SIZE)) // silent frame
          this.lastAudioSentAt = Date.now()
          console.debug('[XfyunRtasr] Keepalive silent frame sent')
        } catch { /* ignore */ }
      }
    }, 5000)
  }

  private stopKeepalive(): void {
    if (this.keepAliveInterval !== null) {
      clearInterval(this.keepAliveInterval)
      this.keepAliveInterval = null
    }
  }

  isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN
  }
}
