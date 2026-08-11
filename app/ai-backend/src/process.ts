/**
 * 编排:音频文件 → 转写 provider(默认 LFASR 批量,带说话人+时间戳) → 拼说话人标注全文
 * → 豆包/方舟 结构化纪要。返回一屏可 dump 的完整结果(转写/纪要/raw/耗时)。
 * 转写经 Transcriber 抽象(可切 lfasr/rtasr);summary 仍走豆包 post-summary(不动)。
 * 任何阶段失败都显式抛出(server 捕获展示),不吞错。
 */

import { createLlmProvider } from './providers/factory'
import type { AppConfig } from './providers/config'
import { generatePostMeetingSummary, postSummaryToMarkdown, type PostMeetingSummary } from './post-summary'
import { assembleTranscript } from './transcript'
import { createTranscriber } from './transcriber-factory'
import type { TranscriberKind, TranscriptSeg } from './transcriber'

export type { TranscriptSeg } from './transcriber'
export type ProcessConfig = AppConfig

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
  const llm = createLlmProvider(cfg.llm)
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
