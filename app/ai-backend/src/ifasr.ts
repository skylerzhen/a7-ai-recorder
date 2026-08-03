/**
 * 讯飞「录音文件转写(大模型版)」批量 provider —— Ifasr_llm / iflyaisol。
 * 异步:POST /v2/upload(原始音频)→ 轮询 POST /v2/getResult → orderResult(lattice)→ TranscriptSeg。
 * 带角色分离(roleType=1)+ 句级时间戳(st.bg/ed),映射成现有契约。
 *
 * 鉴权与 RTASR 大模型版同一套(iflyaisol):signature = Base64(HmacSHA1(已排序的
 * `enc(k)=enc(v)&…`, accessKeySecret)),放 header `signature`;凭据复用 XFYUN_* 三件套:
 *   appId=APPID,accessKeyId=APIKey,accessKeySecret=APISecret。无需新 key。
 */

import { createHmac } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { basename } from 'node:path'
import { probeDurationSec } from './ffmpeg'
import type { Transcriber, TranscribeResult, TranscriptSeg } from './transcriber'

export interface IfasrCfg {
  appId: string
  accessKeyId: string // = APIKey
  accessKeySecret: string // = APISecret
  roleType?: number // 0=关 1=通用角色分离(默认) 3=声纹
  roleNum?: number // 0=盲分自动,2..=指定人数
  language?: string // 默认 autodialect(中文+方言)
  host?: string // 默认 https://office-api-ist-dx.iflyaisol.com
}

/** iflyaisol 鉴权签名:已排序 enc(k)=enc(v) join('&') → HMAC-SHA1 → base64。 */
export function ifasrSign(params: Record<string, string>, accessKeySecret: string): string {
  const base = Object.keys(params)
    .sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`)
    .join('&')
  return createHmac('sha1', accessKeySecret).update(base, 'utf8').digest('base64')
}

interface Cw { w?: string; wp?: string; rl?: string | number }
interface Ws { cw?: Cw[] }
interface Rt { ws?: Ws[] }
interface St { bg?: string | number; ed?: string | number; rl?: string | number; rt?: Rt[] }

/**
 * orderResult(对象或 JSON 串;lattice[].json_1best 内含 cn.st)→ TranscriptSeg[]。
 * 文本 = 各 cw.w 拼接(跳过 wp='g' 段标记);说话人取 cw/st 的 rl(1 基),rl=0 沿用上一个;
 * 时间戳取 st.bg/ed(ms)。映射 说话人{rl}。
 */
export function mapIfasrResult(input: unknown): TranscriptSeg[] {
  let obj: unknown = input
  if (typeof obj === 'string') {
    try { obj = JSON.parse(obj) } catch { return [] }
  }
  const root = obj as { lattice?: unknown[]; lattice2?: unknown[] } | null
  const lattice = root?.lattice ?? root?.lattice2
  if (!Array.isArray(lattice)) return []

  const out: TranscriptSeg[] = []
  let lastRl = 1
  for (const item of lattice) {
    let jb: unknown = (item as { json_1best?: unknown })?.json_1best
    if (typeof jb === 'string') {
      try { jb = JSON.parse(jb) } catch { continue }
    }
    const st = ((jb as { st?: St; cn?: { st?: St } })?.st ?? (jb as { cn?: { st?: St } })?.cn?.st)
    if (!st) continue

    const bg = Number(st.bg ?? 0) || 0
    const ed = Number(st.ed ?? 0) || 0
    let text = ''
    let segRl = 0
    for (const rt of st.rt ?? []) {
      for (const ws of rt.ws ?? []) {
        for (const cw of ws.cw ?? []) {
          if ((cw.wp ?? 'n') === 'g') continue
          const rl = cw.rl !== undefined ? Number(cw.rl) : undefined
          if (rl !== undefined && Number.isFinite(rl) && rl !== 0) segRl = rl
          text += cw.w ?? ''
        }
      }
    }
    if (segRl === 0 && st.rl !== undefined) {
      const r = Number(st.rl)
      if (Number.isFinite(r) && r !== 0) segRl = r
    }
    const rl = segRl || lastRl
    lastRl = rl
    const t = text.trim()
    if (!t) continue
    out.push({ speaker: `说话人${rl}`, text: t, startMs: bg, endMs: ed, isFinal: true })
  }
  return out
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

function isoOffset(d: Date): string {
  const tz = d.getTimezoneOffset()
  const sign = tz <= 0 ? '+' : '-'
  const ah = String(Math.floor(Math.abs(tz) / 60)).padStart(2, '0')
  const am = String(Math.abs(tz) % 60).padStart(2, '0')
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}${sign}${ah}${am}`
}

function qs(params: Record<string, string>): string {
  return Object.entries(params)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join('&')
}

/** signatureRandom:讯飞要求「16 位大小写字母+数字」(不能用带连字符的 UUID,否则 000002)。 */
function nonce16(): string {
  const c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'
  let r = ''
  for (let i = 0; i < 16; i++) r += c[Math.floor(Math.random() * c.length)]
  return r
}

export class IfasrTranscriber implements Transcriber {
  constructor(private cfg: IfasrCfg) {}

  private get host(): string {
    return this.cfg.host ?? 'https://office-api-ist-dx.iflyaisol.com'
  }

  async transcribe(inputPath: string): Promise<TranscribeResult> {
    if (!this.cfg.accessKeyId || !this.cfg.accessKeySecret) {
      throw new Error('缺少讯飞 accessKeyId/accessKeySecret(APIKey/APISecret;复用 XFYUN_ACCESS_KEY_*)')
    }
    const t0 = Date.now()
    const bytes = await readFile(inputPath)
    const durationSec = await probeDurationSec(inputPath).catch(() => 0)
    const timings: Record<string, number> = {}

    // ① upload:原始音频 + 角色分离参数 → orderId
    const upParams: Record<string, string> = {
      appId: this.cfg.appId,
      accessKeyId: this.cfg.accessKeyId,
      dateTime: isoOffset(new Date()),
      signatureRandom: nonce16(),
      fileSize: String(bytes.length),
      fileName: basename(inputPath),
      duration: String(Math.max(1, Math.round(durationSec * 1000))),
      language: this.cfg.language ?? 'autodialect',
      roleType: String(this.cfg.roleType ?? 1),
      roleNum: String(this.cfg.roleNum ?? 0),
    }
    const tUp = Date.now()
    const up = await this.call('upload', '/v2/upload', upParams, {
      headers: { 'Content-Type': 'application/octet-stream' },
      body: new Uint8Array(bytes),
    })
    const orderId = String(up?.content?.orderId ?? up?.orderId ?? '')
    if (!orderId) throw new Error(`LFASR upload 无 orderId: ${JSON.stringify(up).slice(0, 300)}`)
    timings.uploadMs = Date.now() - tUp

    // ② 轮询 getResult(status=4 完成);带回 orderResult
    const tPoll = Date.now()
    let orderResult: unknown = null
    let lastStatus = -99
    for (let i = 0; i < 300; i++) {
      // getResult 文档参数集不含 appId(只 accessKeyId)——严格按文档,避免签名串多带参数
      const qParams: Record<string, string> = {
        accessKeyId: this.cfg.accessKeyId,
        dateTime: isoOffset(new Date()),
        signatureRandom: nonce16(),
        orderId,
        resultType: 'transfer',
      }
      const j = await this.call('getResult', '/v2/getResult', qParams, {
        headers: { 'Content-Type': 'application/json' },
        body: '{}',
      })
      const info = j?.content?.orderInfo ?? j?.orderInfo
      lastStatus = Number(info?.status ?? -99)
      const failed = Number(info?.failType ?? 0)
      if (lastStatus === 4) {
        orderResult = j?.content?.orderResult ?? j?.orderResult
        break
      }
      if (lastStatus === -1 || failed > 0) {
        throw new Error(`LFASR 转写失败 status=${lastStatus} failType=${failed}`)
      }
      await sleep(3000)
    }
    if (orderResult == null) throw new Error(`LFASR 轮询超时(末状态 status=${lastStatus})`)
    timings.transcribeMs = Date.now() - tPoll

    const segments = mapIfasrResult(orderResult)
    timings.totalMs = Date.now() - t0
    return {
      segments,
      raw: { orderId, lastStatus, orderResult },
      durationSec: durationSec || (segments.length ? Math.max(...segments.map((s) => s.endMs ?? 0)) / 1000 : 0),
      timings,
    }
  }

  private async call(
    action: string,
    path: string,
    params: Record<string, string>,
    init: { headers: Record<string, string>; body: BodyInit },
  ): Promise<any> {
    const signature = ifasrSign(params, this.cfg.accessKeySecret)
    const res = await fetch(`${this.host}${path}?${qs(params)}`, {
      method: 'POST',
      headers: { ...init.headers, signature },
      body: init.body,
    })
    const txt = await res.text()
    let j: any
    try {
      j = JSON.parse(txt)
    } catch {
      throw new Error(`LFASR ${action} 非 JSON(${res.status}): ${txt.slice(0, 200)}`)
    }
    const code = String(j?.code ?? '')
    if (code && code !== '000000') {
      throw new Error(`LFASR ${action} 失败 code=${code} ${j?.descInfo ?? j?.desc ?? ''}`)
    }
    return j
  }
}
