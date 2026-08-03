/**
 * 临时联调/验收脚本(不改产品代码):用真账号跑「录音文件转写大模型版」批量转写,
 * 测端到端耗时 + 打印说话人/时间戳,验证契约。用法:
 *   node --import tsx ifasr-check.ts [音频路径,默认 ../../web/downloaded.mp3]
 */
import 'dotenv/config'
import { IfasrTranscriber } from './src/ifasr'

const path = process.argv[2] ?? '../../web/downloaded.mp3'

const t = new IfasrTranscriber({
  appId: process.env.XFYUN_APP_ID!,
  accessKeyId: process.env.XFYUN_ACCESS_KEY_ID!,
  accessKeySecret: process.env.XFYUN_ACCESS_KEY_SECRET!,
  roleType: Number(process.env.LFASR_ROLE_TYPE ?? 1),
  roleNum: Number(process.env.LFASR_ROLE_NUM ?? 0),
})

const t0 = Date.now()
try {
  const res = await t.transcribe(path)
  const wall = ((Date.now() - t0) / 1000).toFixed(1)
  console.log(`\n✅ 完成:墙钟 ${wall}s  音频≈${(res.durationSec ?? 0).toFixed(0)}s  段数=${res.segments.length}`)
  console.log('timings(ms):', res.timings)
  const speakers = [...new Set(res.segments.map((s) => s.speaker))]
  console.log('说话人:', speakers.join(', '))
  console.log('--- 前 12 段(说话人 时间戳 文本)---')
  for (const s of res.segments.slice(0, 12)) {
    console.log(`[${s.speaker} ${s.startMs}~${s.endMs}ms] ${s.text}`)
  }
} catch (e) {
  console.error('\n❌ 失败:', e instanceof Error ? e.message : e)
  process.exit(1)
}
