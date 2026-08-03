import { test } from 'node:test'
import assert from 'node:assert/strict'
import { decodeToPcm16kMono, pcmDurationSec } from '../src/ffmpeg'

// 真 A7 录音样本(B0B3 实时流抓的 live_b3.mp3,MPEG-2 L3 16kHz/mono/32kbps,≈14s)。
// 验证 ffmpeg 解码出的 PCM 参数正确(s16le/16k/mono → 长度与时长一致)。
test('解码真 A7 MP3 → PCM s16le/16k/mono,时长合理', async () => {
  const pcm = await decodeToPcm16kMono('test/fixtures/live_b3.mp3')
  assert.ok(pcm.length > 0, 'PCM 非空')
  assert.equal(pcm.length % 2, 0, 's16le 每样本 2 字节,总长应为偶数')
  const sec = pcmDurationSec(pcm.length)
  assert.ok(sec > 10 && sec < 20, `时长 ${sec.toFixed(1)}s 应在 ~14s 附近`)
})
