/**
 * 可插拔「AI 大脑」—— 会议副驾的核心接口。换 Agent OS 只动这里,路由不写死豆包。
 * 本棒(1A)只实现 ask(会中问 AI,流式);advise(主动提示,1B)/ summarize(1C)留占位。
 */

import { LLMClient } from './llm-client'

export interface MeetingContext {
  goal?: string // 本场目标(我方想从这场拿到什么)
  transcript: string // 实时逐字稿(可能不完整)
  clientBackground?: string // 会前情报:这位客户是谁 / 什么关系 / 惯用套路(过往了解,未必在本场出现)
}

export interface LiveCue {
  shouldPrompt: boolean
  cue: string
  rationale: string
}

export interface BrainProvider {
  /** 会中问 AI:逐 token 流式吐「小抄」。本棒实现。 */
  ask(ctx: MeetingContext, question: string): AsyncIterable<string>
  /** 主动提示(1B):该不该插话 + 插什么。 */
  advise(ctx: MeetingContext): Promise<LiveCue>
  /** 会后纪要:从已有逐字稿出可读 markdown 纪要,逐 token 流式(LLM-only,不重转写)。 */
  summarize(ctx: MeetingContext): AsyncIterable<string>
}

/** 客户背景注入上限:超长截断,避免把 prompt 撑爆。 */
const MAX_CLIENT_BG = 4000

/** 取规整后的客户背景(空 → 空串;超长 → 截断 + 提示)。 */
function clientBg(ctx: MeetingContext): string {
  const bg = (ctx.clientBackground ?? '').trim()
  if (!bg) return ''
  return bg.length > MAX_CLIENT_BG ? `${bg.slice(0, MAX_CLIENT_BG)}\n…(客户背景较长,已截断)` : bg
}

/**
 * 纯逻辑:构造「问 AI」的 system + user。
 * 立场:坐在「佩戴录音笔的我方」耳边,帮我方准备下一句该说/该问;goal 非空就紧扣本场目标。
 * 有【客户背景】时额外注入,让小抄更贴合这位客户。
 */
export function buildAskPrompt(
  ctx: MeetingContext,
  question: string,
): { system: string; user: string } {
  const goal = (ctx.goal ?? '').trim()
  const bg = clientBg(ctx)
  const system = [
    '你是会议副驾,坐在「佩戴录音笔的我方」耳边。',
    '依据【实时逐字稿】(可能不完整、有错别字)和【本场目标】,直接给我方一张可照着说/照着问的「小抄」。',
    '只给能直接说出口的话术或要点:简洁、口语、贴合刚才的对话;不要复述我的问题、不要寒暄、不要解释你在做什么。',
    ...(bg
      ? ['我已掌握这位客户的【客户背景】(过往了解,未必在本场被提到):请结合它,给出更贴合 TA 的话术与提醒。']
      : []),
    goal
      ? '紧扣【本场目标】,帮我方把「这场要拿到的东西」往前推一步。'
      : '未给目标时,围绕刚才的对话帮我方接好下一句。',
  ].join('\n')
  const parts = [goal ? `【本场目标】${goal}` : '【本场目标】(未填)']
  if (bg) parts.push('', '【客户背景】', bg)
  parts.push('', '【实时逐字稿】', ctx.transcript.trim() || '(暂无)', '', `【我的问题】${question.trim()}`)
  return { system, user: parts.join('\n') }
}

/**
 * 纯逻辑:构造「主动提示」的 system + user。命脉=克制(多数 shouldPrompt:false)。
 * cue = 能直接说出口的一句话;只在高价值且此刻自然时才 true。
 */
export function buildAdvisePrompt(ctx: MeetingContext): { system: string; user: string } {
  const goal = (ctx.goal ?? '').trim()
  const bg = clientBg(ctx)
  const system = [
    '你是会议副驾,坐在「佩戴录音笔的我方」耳边,只在关键时刻才递一句小抄。',
    '判断此刻是否值得主动提醒我方,核心是【克制】:',
    '- 绝大多数情况答 shouldPrompt:false —— 没有明确高价值点,或此刻插话不自然,就保持安静;宁可不提,也绝不刷屏。',
    '- 仅当确实存在一个「高价值且此刻说出来自然不突兀」的点(关键信息缺口、该追问、该确认、风险/承诺需锁定)才 shouldPrompt:true。',
    ...(bg
      ? ['已掌握这位客户的【客户背景】(过往了解,未必在本场被提到):结合它判断什么对 TA 才是真正高价值的提醒。']
      : []),
    goal
      ? '紧扣【本场目标】,服务我方「下一句该说/该问什么」。'
      : '围绕刚才的对话,服务我方「下一句该说/该问什么」。',
    'cue 必须是能直接说出口的一句话(话术/追问/提醒),不要审计式提问;rationale 一句话。',
    '只输出严格 JSON,不要任何多余文字、不要代码块:',
    '{"shouldPrompt": true 或 false, "cue": "能直接说出口的一句话", "rationale": "一句话理由"}',
    'shouldPrompt 为 false 时 cue 用空字符串。',
  ].join('\n')
  const parts = [goal ? `【本场目标】${goal}` : '【本场目标】(未填)']
  if (bg) parts.push('', '【客户背景】', bg)
  parts.push('', '【实时逐字稿(到此为止)】', ctx.transcript.trim() || '(暂无)')
  return { system, user: parts.join('\n') }
}

/**
 * 纯逻辑:构造「会后纪要(流式 markdown)」的 system + user。
 * 输出可读 markdown(叙事/决定/行动项/待解决/收获);有 goal/clientBackground 时更贴本场。
 */
export function buildSummaryStreamPrompt(ctx: MeetingContext): { system: string; user: string } {
  const goal = (ctx.goal ?? '').trim()
  const bg = clientBg(ctx)
  const system = [
    '你是会议总结专家。基于【会议转写】(已标注说话人),输出一份可读的会后纪要。',
    '直接用 Markdown 正文输出,按这几节组织(某节确实没内容就省略该节):',
    '## 叙事(300-500 字完整总结)',
    '## 决定',
    '## 行动项(尽量带负责人/时间)',
    '## 待解决',
    '## 收获',
    '只输出纪要正文,不要解释你在做什么,不要用代码块包裹。',
    ...(bg ? ['结合【客户背景】,让纪要更贴合这位客户。'] : []),
    ...(goal ? ['结合【本场目标】,突出与目标相关的进展与缺口。'] : []),
  ].join('\n')
  const parts: string[] = []
  if (goal) parts.push(`【本场目标】${goal}`)
  if (bg) parts.push(`【客户背景】${bg}`)
  parts.push('', '【会议转写】', ctx.transcript.trim() || '(暂无)')
  return { system, user: parts.join('\n') }
}

/**
 * 容错解析 advise 的 LLM 输出 → LiveCue。仿 post-summary:抽首个 JSON 对象再 parse。
 * 任何失败 = shouldPrompt:false(绝不抛、绝不崩);shouldPrompt:true 但 cue 空也收敛为 false。
 */
export function parseAdvise(raw: string): LiveCue {
  const fail: LiveCue = { shouldPrompt: false, cue: '', rationale: '' }
  const m = raw.match(/\{[\s\S]*\}/)
  if (!m) return fail
  try {
    const j = JSON.parse(m[0]) as { shouldPrompt?: unknown; cue?: unknown; rationale?: unknown }
    const cue = String(j.cue ?? '').trim()
    const shouldPrompt = j.shouldPrompt === true && cue.length > 0
    return {
      shouldPrompt,
      cue: shouldPrompt ? cue : '',
      rationale: String(j.rationale ?? '').trim(),
    }
  } catch {
    return fail
  }
}

/** 把回调式 streamChat 桥接成 AsyncIterable<string>,逐 token 吐出(ask / summarize 共用)。 */
async function* streamLlm(
  llm: LLMClient,
  system: string,
  user: string,
  maxTokens: number,
): AsyncIterable<string> {
  const queue: string[] = []
  let done = false
  let err: string | null = null
  let wake: (() => void) | null = null
  const signal = () => {
    if (wake) {
      const w = wake
      wake = null
      w()
    }
  }

  const p = llm.streamChat({
    system,
    messages: [{ role: 'user', content: user }],
    maxTokens,
    onText: (t) => {
      queue.push(t)
      signal()
    },
    onDone: () => {
      done = true
      signal()
    },
    onError: (e) => {
      err = e
      done = true
      signal()
    },
  })

  while (true) {
    while (queue.length > 0) yield queue.shift()!
    if (err) {
      await p.catch(() => {})
      throw new Error(err)
    }
    if (done) break
    await new Promise<void>((r) => {
      wake = r
    })
  }
  await p.catch(() => {})
}

/** 默认大脑:走 OpenAI 兼容 LLM(豆包/方舟)。 */
export class LlmBrain implements BrainProvider {
  constructor(private llm: LLMClient) {}

  /** 会中问 AI:逐 token 流式吐「小抄」。 */
  async *ask(ctx: MeetingContext, question: string): AsyncIterable<string> {
    const { system, user } = buildAskPrompt(ctx, question)
    yield* streamLlm(this.llm, system, user, 500)
  }

  /**
   * 主动提示(被动·克制):单次小决策,非流式。
   * LLM 调用失败 → 向上抛(/advise 以 500 暴露,前端可见);
   * LLM 有返回但非 JSON → parseAdvise 收敛为 shouldPrompt:false(安静,不崩)。
   */
  async advise(ctx: MeetingContext): Promise<LiveCue> {
    const { system, user } = buildAdvisePrompt(ctx)
    const raw = await this.llm.generateShort({ system, prompt: user, maxTokens: 300 })
    return parseAdvise(raw)
  }

  /** 会后纪要:逐 token 流式吐可读 markdown(LLM-only,不重转写;带 goal/clientBackground)。 */
  async *summarize(ctx: MeetingContext): AsyncIterable<string> {
    const { system, user } = buildSummaryStreamPrompt(ctx)
    yield* streamLlm(this.llm, system, user, 2048)
  }
}
