import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildSummaryPrompt, generatePostMeetingSummary } from '../src/post-summary'
import type { LLMClient } from '../src/llm-client'

// 假 LLMClient:只实现 generateShort,用于不连网测纪要逻辑。
function fakeLlm(impl: () => Promise<string>): LLMClient {
  return { generateShort: impl } as unknown as LLMClient
}

test('P0-a:LLM 抛错时返回 {summary:null,error},绝不向上抛(转写不被连累)', async () => {
  const llm = fakeLlm(async () => {
    throw new Error('HTTP 429: rate limit')
  })
  const res = await generatePostMeetingSummary({ llmClient: llm, transcriptText: '[说话人1] 你好' })
  assert.equal(res.summary, null)
  assert.match(res.error ?? '', /LLM 调用失败/)
  assert.match(res.error ?? '', /429/)
})

test('LLM 返回合法 JSON → 解析出 summary', async () => {
  const llm = fakeLlm(async () =>
    '{"narrative":"叙事","decisions":["d1"],"actionItems":[],"openQuestions":[],"takeaways":["t1"]}')
  const res = await generatePostMeetingSummary({ llmClient: llm, transcriptText: 'x' })
  assert.equal(res.summary?.narrative, '叙事')
  assert.deepEqual(res.summary?.decisions, ['d1'])
})

test('summary prompt 内嵌转写与 JSON 输出契约', () => {
  const p = buildSummaryPrompt('[说话人1] 你好', { durationMinutes: 1.5, speakers: ['说话人1', '说话人2'] })
  assert.match(p, /\[说话人1\] 你好/)
  assert.match(p, /"narrative"/)
  assert.match(p, /"decisions"/)
  assert.match(p, /"actionItems"/)
  assert.match(p, /"openQuestions"/)
  assert.match(p, /"takeaways"/)
  assert.match(p, /只返回 JSON/)
  assert.match(p, /1\.5 分钟/)
  assert.match(p, /说话人1, 说话人2/)
})

test('buildSummaryPrompt:带 context → 注入会前背景块,转写仍在', () => {
  const p = buildSummaryPrompt('[说话人1] 你好', undefined, '【本场目标】签年框\n【客户背景】惯压账期')
  assert.match(p, /会前背景/)
  assert.match(p, /签年框/)
  assert.match(p, /惯压账期/)
  assert.match(p, /\[说话人1\] 你好/) // 转写段仍在
})
