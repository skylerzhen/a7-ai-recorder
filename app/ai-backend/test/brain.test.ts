import { test } from 'node:test'
import assert from 'node:assert/strict'
import { buildAskPrompt, buildAdvisePrompt, parseAdvise, LlmBrain } from '../src/brain'
import type { LLMClient } from '../src/llm-client'

// 「问 AI」prompt 立场:帮「佩戴录音笔的我方」准备下一句该说/该问;goal 非空就围绕本场目标。
test('buildAskPrompt:有目标 → system 立场 + user 含目标/逐字稿/问题', () => {
  const { system, user } = buildAskPrompt(
    { goal: '谈下 30 天交付', transcript: '对方:预算大概十万。' },
    '现在我该追问什么把预算问清楚?',
  )
  // 立场:帮我方、给小抄、别复述
  assert.match(system, /我方/)
  assert.match(system, /小抄/)
  // user 三件:目标 / 逐字稿 / 问题 都带上
  assert.match(user, /谈下 30 天交付/)
  assert.match(user, /对方:预算大概十万。/)
  assert.match(user, /现在我该追问什么把预算问清楚\?/)
})

test('buildAskPrompt:无目标 → 标「未填」且不崩', () => {
  const { user } = buildAskPrompt({ transcript: '随便聊聊' }, '他刚说啥?')
  assert.match(user, /未填/)
  assert.match(user, /随便聊聊/)
  assert.match(user, /他刚说啥\?/)
})

test('buildAskPrompt:空逐字稿 → 占位(暂无)', () => {
  const { user } = buildAskPrompt({ goal: 'x', transcript: '   ' }, '问题')
  assert.match(user, /暂无/)
})

// ── advise(主动克制提示)──
test('buildAdvisePrompt:system 强调克制 + JSON 契约;user 带目标/逐字稿', () => {
  const { system, user } = buildAdvisePrompt({ goal: '锁定交付与预算', transcript: '对方:预算十万。' })
  // 克制命脉:多数 false、保持安静、宁可不提
  assert.match(system, /false/)
  assert.match(system, /安静|不提|克制/)
  // 我方立场 + JSON 形状
  assert.match(system, /我方/)
  assert.match(system, /shouldPrompt/)
  assert.match(system, /cue/)
  assert.match(user, /锁定交付与预算/)
  assert.match(user, /对方:预算十万。/)
})

test('parseAdvise:合法 true JSON → LiveCue', () => {
  const c = parseAdvise('{"shouldPrompt": true, "cue": "您说的十万是封顶吗?", "rationale": "预算上限未锁定"}')
  assert.equal(c.shouldPrompt, true)
  assert.equal(c.cue, '您说的十万是封顶吗?')
  assert.equal(c.rationale, '预算上限未锁定')
})

test('parseAdvise:带 ```json 代码块 → 能抽出', () => {
  const c = parseAdvise('```json\n{"shouldPrompt": false, "cue": "", "rationale": "暂无高价值点"}\n```')
  assert.equal(c.shouldPrompt, false)
})

test('parseAdvise:非 JSON / 垃圾 → shouldPrompt:false 不崩不抛', () => {
  assert.equal(parseAdvise('我觉得现在不需要提示。').shouldPrompt, false)
  assert.equal(parseAdvise('').shouldPrompt, false)
  assert.equal(parseAdvise('{坏的').shouldPrompt, false)
})

test('parseAdvise:true 但 cue 空 → 收敛为 false(不拿空话打扰)', () => {
  const c = parseAdvise('{"shouldPrompt": true, "cue": "   ", "rationale": "x"}')
  assert.equal(c.shouldPrompt, false)
})

// ── 2-CTX 会前客户背景注入 ──
test('buildAskPrompt:有客户背景 → system 提结合背景、user 含【客户背景】块', () => {
  const { system, user } = buildAskPrompt(
    { goal: '签年框', transcript: '对方:再聊聊。', clientBackground: '这客户惯压账期、只认价格,采购老王说了算。' },
    '我该怎么开口?',
  )
  assert.match(system, /客户背景/)
  assert.match(user, /【客户背景】/)
  assert.match(user, /惯压账期/)
  assert.match(user, /采购老王/)
})

test('buildAskPrompt:无客户背景 → 不注入【客户背景】块(向后兼容)', () => {
  const { system, user } = buildAskPrompt({ goal: 'x', transcript: 'y' }, 'z')
  assert.doesNotMatch(user, /【客户背景】/)
  assert.doesNotMatch(system, /客户背景/)
})

test('buildAdvisePrompt:有客户背景 → system 提结合背景、user 含【客户背景】块', () => {
  const { system, user } = buildAdvisePrompt({
    transcript: '对方:这价格有点高。',
    clientBackground: '这客户认价格、惯用拖延逼让步。',
  })
  assert.match(system, /客户背景/)
  assert.match(user, /【客户背景】/)
  assert.match(user, /惯用拖延/)
})

test('buildAskPrompt:超长客户背景 → 截断 + 提示,不撑爆 prompt', () => {
  const huge = '甲'.repeat(5000)
  const { user } = buildAskPrompt({ transcript: 't', clientBackground: huge }, 'q')
  assert.match(user, /已截断/)
  assert.ok(!user.includes('甲'.repeat(5000))) // 完整 5000 串已被截到 ~4000
})

// ── summarize(流式 markdown):goal/clientBackground 注入 prompt + 逐 token 产出 ──
test('LlmBrain.summarize(流式):注入 goal/clientBackground 到 prompt,逐 token 产出', async () => {
  let captured = ''
  const llm = {
    streamChat: async (p: {
      system: string
      messages: { content: string }[]
      onText: (t: string) => void
      onDone: () => void
    }) => {
      captured = `${p.system}\n${p.messages[0].content}`
      p.onText('## 叙事\n')
      p.onText('达成共识')
      p.onDone()
    },
  } as unknown as LLMClient
  let out = ''
  for await (const t of new LlmBrain(llm).summarize({
    transcript: '[说话人1] 预算十万',
    goal: '签年框',
    clientBackground: '惯压账期',
  })) {
    out += t
  }
  assert.match(out, /叙事/) // 逐 token 拼回 markdown
  assert.match(out, /达成共识/)
  assert.match(captured, /签年框/) // goal 进了 prompt
  assert.match(captured, /惯压账期/) // 客户背景进了 prompt
  assert.match(captured, /预算十万/) // 逐字稿在
})

test('LlmBrain.summarize(流式):LLM 出错 → 迭代抛出,不静默', async () => {
  const llm = {
    streamChat: async (p: { onError: (e: string) => void; onDone: () => void }) => {
      p.onError('HTTP 500')
      p.onDone()
    },
  } as unknown as LLMClient
  await assert.rejects(async () => {
    for await (const _ of new LlmBrain(llm).summarize({ transcript: 'x' })) {
      // drain
    }
  }, /HTTP 500/)
})
