import { test } from 'node:test'
import assert from 'node:assert/strict'
import { speakerLabel, assembleTranscript } from '../src/transcript'

test('speakerLabel 映射 you/them → 说话人1/说话人2', () => {
  assert.equal(speakerLabel('you'), '说话人1')
  assert.equal(speakerLabel('them'), '说话人2')
})

test('拼装:连续同一说话人合并为一行', () => {
  const out = assembleTranscript([
    { speaker: '说话人1', text: '你好' },
    { speaker: '说话人1', text: '今天开会' },
    { speaker: '说话人2', text: '好的' },
  ])
  assert.equal(out, '[说话人1] 你好今天开会\n[说话人2] 好的')
})

test('空 → 空串', () => {
  assert.equal(assembleTranscript([]), '')
})

test('跳过空白文本', () => {
  const out = assembleTranscript([
    { speaker: '说话人1', text: '  ' },
    { speaker: '说话人1', text: '实质内容' },
  ])
  assert.equal(out, '[说话人1] 实质内容')
})
