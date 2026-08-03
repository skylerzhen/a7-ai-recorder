import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mp3SyncOffset } from '../src/stream-session'

// Bug-2:真机 B0B3 可能从帧中间起步,首批裁到首个帧同步(镜像 a7_protocol trimToMp3Sync)。
test('已对齐(ff f3 开头)→ 0', () => {
  assert.equal(mp3SyncOffset(Buffer.from([0xff, 0xf3, 0x48, 0xc4])), 0)
})

test('中间帧起步:跳过前导垃圾到首个同步', () => {
  assert.equal(mp3SyncOffset(Buffer.from([0x11, 0x22, 0x33, 0xff, 0xf3, 0x48])), 3)
})

test('无效 0xFF(次字节非同步)不误判', () => {
  assert.equal(mp3SyncOffset(Buffer.from([0xff, 0x00, 0xff, 0xfb, 0x90])), 2)
})

test('找不到 → -1', () => {
  assert.equal(mp3SyncOffset(Buffer.from([0x00, 0x01, 0x02])), -1)
})
