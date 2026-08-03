import { IfasrTranscriber, type IfasrCfg } from './ifasr'
import { RtasrRealtimeTranscriber, type RtasrCfg } from './rtasr-transcriber'
import type { Transcriber, TranscriberKind } from './transcriber'

/** 按 kind 造转写 provider(/process 用)。默认 lfasr=录音文件转写大模型版(批量)。 */
export function createTranscriber(
  kind: TranscriberKind,
  opts: { rtasr: RtasrCfg; ifasr: IfasrCfg },
): Transcriber {
  return kind === 'rtasr'
    ? new RtasrRealtimeTranscriber(opts.rtasr)
    : new IfasrTranscriber(opts.ifasr)
}
