import { test } from 'node:test'
import assert from 'node:assert/strict'
import { chunkPcmFrames } from '../src/framing'

// 讯飞 RTASR 要 1280B/帧的 PCM s16le。分帧器:整除→N 个满帧;余数→末帧补零到 1280。
test('整除 → N 个满帧', () => {
  const frames = chunkPcmFrames(Buffer.alloc(2560), 1280)
  assert.equal(frames.length, 2)
  assert.equal(frames[0].length, 1280)
  assert.equal(frames[1].length, 1280)
})

test('余数末帧补零到 1280', () => {
  const buf = Buffer.alloc(1500, 0xab)
  const frames = chunkPcmFrames(buf, 1280)
  assert.equal(frames.length, 2)
  assert.equal(frames[1].length, 1280)
  assert.equal(frames[1][219], 0xab) // 220B 真实数据(1500-1280)
  assert.equal(frames[1][220], 0x00) // 之后补零
})

test('空输入 → 无帧', () => {
  assert.equal(chunkPcmFrames(Buffer.alloc(0)).length, 0)
})

test('默认帧长 1280', () => {
  assert.equal(chunkPcmFrames(Buffer.alloc(1280))[0].length, 1280)
})
