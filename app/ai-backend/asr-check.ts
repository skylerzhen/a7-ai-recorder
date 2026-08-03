/**
 * 临时校验脚本(供验收,不改后端产品代码):只跑讯飞 RTASR 那半,
 * 复用后端模块,把真 A7 录音的转写(说话人+时间戳)打印出来。不需要方舟 key。
 * 用法:node --import tsx asr-check.ts [音频路径]
 */
import 'dotenv/config'
import { decodeToPcm16kMono, pcmDurationSec } from './src/ffmpeg'
import { chunkPcmFrames } from './src/framing'
import { XfyunRtasrClient } from './src/xfyun-rtasr'
import { speakerLabel, assembleTranscript } from './src/transcript'

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

async function main() {
  const path = process.argv[2] || '/Users/eddie/Desktop/proj/Hospital/web/downloaded.mp3'
  const frameMs = Number(process.env.RTASR_FRAME_MS ?? 10)

  const pcm = await decodeToPcm16kMono(path)
  console.log(`音频: ${path}  时长≈${pcmDurationSec(pcm.length).toFixed(1)}s  frameMs=${frameMs}`)
  const frames = chunkPcmFrames(pcm, 1280)

  const finals: { speaker: string; text: string; startMs?: number; endMs?: number }[] = []
  const client = new XfyunRtasrClient({
    appId: process.env.XFYUN_APP_ID!,
    accessKeyId: process.env.XFYUN_ACCESS_KEY_ID!,
    accessKeySecret: process.env.XFYUN_ACCESS_KEY_SECRET!,
  })
  client.onTranscript = (text, speaker, isFinal, speakerName, startMs, endMs) => {
    if (isFinal && text.trim()) finals.push({ speaker: speakerName || speakerLabel(speaker), text, startMs, endMs })
  }

  const ok = await client.connect()
  if (!ok) { console.error('❌ 讯飞连接失败'); process.exit(1) }
  console.log(`发帧中… 共 ${frames.length} 帧`)
  for (const f of frames) { client.sendAudio(f); if (frameMs > 0) await sleep(frameMs) }
  await client.finish(5000)

  console.log('\n===== 转写(final 段,说话人+时间戳)=====')
  if (finals.length === 0) console.log('(无 final 段——可能是静音/无语音)')
  for (const s of finals) console.log(`[${s.speaker}${s.startMs != null ? ` ${s.startMs}~${s.endMs}ms` : ''}] ${s.text}`)
  console.log('\n===== 拼装全文 =====')
  console.log(assembleTranscript(finals.map((s) => ({ speaker: s.speaker, text: s.text }))) || '(空)')
  process.exit(0)
}
main()
