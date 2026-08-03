/**
 * 编排:音频文件 → 转写 provider(默认 LFASR 批量,带说话人+时间戳) → 拼说话人标注全文
 * → 豆包/方舟 结构化纪要。返回一屏可 dump 的完整结果(转写/纪要/raw/耗时)。
 * 转写经 Transcriber 抽象(可切 lfasr/rtasr);summary 仍走豆包 post-summary(不动)。
 * 任何阶段失败都显式抛出(server 捕获展示),不吞错。
 */

import { LLMClient } from './llm-client'
import { generatePostMeetingSummary, postSummaryToMarkdown, type PostMeetingSummary } from './post-summary'
import { assembleTranscript } from './transcript'
import { createTranscriber } from './transcriber-factory'
import type { TranscriberKind, TranscriptSeg } from './transcriber'
import type { IfasrCfg } from './ifasr'

export type { TranscriptSeg } from './transcriber'

export interface ProcessConfig {
  /** 异步 /process 用哪种转写;默认 lfasr(录音文件转写大模型版,批量,分钟级)。 */
  transcriber: TranscriberKind
  /** iflyaisol WebAPI 凭据(RTASR 实时 + LFASR 批量 + /stream 共用同一套)。 */
  xfyun: { appId: string; accessKeyId: string; accessKeySecret: string }
  /** LFASR(批量,大模型版)配置;凭据复用 xfyun。 */
  ifasr: IfasrCfg
  ark: { apiKey: string; model: string; baseURL: string }
  /** 仅 rtasr 兜底时的发帧间隔。 */
  frameMs: number
}

export interface ProcessResult {
  transcript: TranscriptSeg[]
  summary: PostMeetingSummary | null
  summaryMarkdown: string | null
  raw: {
    transcriber: TranscriberKind
    asr: unknown
    llmRaw: string
    llmError?: string
    durationSec: number
    transcriptText: string
  }
  timings: Record<string, number>
}

export async function processAudio(inputPath: string, cfg: ProcessConfig): Promise<ProcessResult> {
  const t0 = Date.now()
  const timings: Record<string, number> = {}

  // ① 转写(provider 可切:默认 LFASR 批量 → 分钟级;rtasr 兜底 ≈ 音频时长)
  const transcriber = createTranscriber(cfg.transcriber, {
    rtasr: { ...cfg.xfyun, frameMs: cfg.frameMs },
    ifasr: cfg.ifasr,
  })
  const tAsr = Date.now()
  const asr = await transcriber.transcribe(inputPath)
  timings.asrMs = Date.now() - tAsr
  Object.assign(timings, asr.timings ?? {})
  const durationSec = asr.durationSec ?? 0

  // ② 拼说话人标注全文(只取 final)
  const finals = asr.segments.filter((s) => s.isFinal)
  const transcriptText = assembleTranscript(finals.map((s) => ({ speaker: s.speaker, text: s.text })))
  const speakers = [...new Set(finals.map((s) => s.speaker))]

  // ③ 豆包/方舟 结构化纪要(不动)
  const tLlm = Date.now()
  const llm = new LLMClient(cfg.ark)
  const sumRes = await generatePostMeetingSummary({
    llmClient: llm,
    transcriptText,
    meta: { durationMinutes: durationSec / 60, speakers },
  })
  timings.llmMs = Date.now() - tLlm
  timings.totalMs = Date.now() - t0

  return {
    transcript: asr.segments,
    summary: sumRes.summary,
    summaryMarkdown: sumRes.summary ? postSummaryToMarkdown(sumRes.summary, { duration: durationSec / 60 }) : null,
    raw: {
      transcriber: cfg.transcriber,
      asr: asr.raw,
      llmRaw: sumRes.rawText,
      llmError: sumRes.error,
      durationSec,
      transcriptText,
    },
    timings,
  }
}
