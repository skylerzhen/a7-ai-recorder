/**
 * 转写 provider 抽象:把「音频 → 带说话人+时间戳的分段」这步从具体 ASR 解耦,可切换。
 * /process 通过本接口拿转写,后续 summary 仍走豆包;/stream 实时字幕另走 RTASR 不经此。
 */

export interface TranscriptSeg {
  speaker: string
  text: string
  startMs?: number
  endMs?: number
  isFinal: boolean
}

export interface TranscribeResult {
  segments: TranscriptSeg[]
  /** 原始结果 / 事件,放进 ProcessResult.raw 供排查。 */
  raw: unknown
  /** 音频时长(秒),供 summary 的 durationMinutes;LFASR 由末段 endMs 推得。 */
  durationSec?: number
  /** 各阶段耗时(ms),并入 timings。 */
  timings?: Record<string, number>
}

export interface Transcriber {
  /** 转写一个本地音频文件,返回带说话人+时间戳的 final 分段。 */
  transcribe(inputPath: string): Promise<TranscribeResult>
}

/** 'lfasr' = 讯飞批量(默认,分钟级);'rtasr' = 实时(兜底/基线,≈音频时长)。 */
export type TranscriberKind = 'lfasr' | 'rtasr'
