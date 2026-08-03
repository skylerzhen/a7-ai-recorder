/**
 * RtasrRealtimeTranscriber —— 把原 /process 里的「讯飞 RTASR 实时」转写逻辑包成 Transcriber。
 * 仅作【兜底 / 速度基线】(改前 ≈ 音频时长);/process 默认改用 LFASR 批量。
 * /stream 实时字幕走 stream-session(不经此),保持不动。
 */

import { XfyunRtasrClient } from './xfyun-rtasr'
import { decodeToPcm16kMono, pcmDurationSec } from './ffmpeg'
import { chunkPcmFrames } from './framing'
import { speakerLabel } from './transcript'
import type { Transcriber, TranscribeResult, TranscriptSeg } from './transcriber'

export interface RtasrCfg {
  appId: string
  accessKeyId: string
  accessKeySecret: string
  frameMs: number
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

export class RtasrRealtimeTranscriber implements Transcriber {
  constructor(private cfg: RtasrCfg) {}

  async transcribe(inputPath: string): Promise<TranscribeResult> {
    const t0 = Date.now()
    const pcm = await decodeToPcm16kMono(inputPath)
    const durationSec = pcmDurationSec(pcm.length)
    const frames = chunkPcmFrames(pcm, 1280)
    const segments: TranscriptSeg[] = []
    const asrEvents: unknown[] = []
    let asrError: string | undefined

    const client = new XfyunRtasrClient({
      appId: this.cfg.appId,
      accessKeyId: this.cfg.accessKeyId,
      accessKeySecret: this.cfg.accessKeySecret,
    })
    client.onTranscript = (text, speaker, isFinal, speakerName, startMs, endMs) => {
      const seg: TranscriptSeg = {
        speaker: speakerName || speakerLabel(speaker),
        text,
        startMs,
        endMs,
        isFinal,
      }
      segments.push(seg)
      asrEvents.push({ t: Date.now() - t0, ...seg })
    }
    client.onStatus = (status, detail, meta) => {
      if (status === 'error') asrError = detail
      asrEvents.push({ status, detail, meta })
    }

    const ok = await client.connect()
    if (!ok) throw new Error(`讯飞 RTASR 连接失败: ${asrError ?? '未知(检查 appId/accessKey/网络)'}`)

    for (const f of frames) {
      client.sendAudio(f)
      if (this.cfg.frameMs > 0) await sleep(this.cfg.frameMs)
    }
    await client.finish(3000)

    return {
      segments,
      raw: { asrEvents, asrError, frameCount: frames.length },
      durationSec,
      timings: { asrMs: Date.now() - t0 },
    }
  }
}
