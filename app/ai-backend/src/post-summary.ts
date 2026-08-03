/**
 * 会后纪要生成。改自 web-advisor/src/lib/post-summary.ts。
 *
 * 原版吃 ambient-engine 的 LivingUnderstanding + schema + 知识图谱;本棒**简化为吃说话人
 * 标注的纯转写**直接喂 summary prompt。JSON 输出契约
 * {narrative,decisions,actionItems,openQuestions,takeaways} 与原版一致;
 * postSummaryToMarkdown 逐字保留。prompt 构造抽成纯函数 buildSummaryPrompt(便于单测)。
 */

import { LLMClient } from './llm-client'

export interface PostMeetingSummary {
  /** Full narrative summary (no length limit) */
  narrative: string
  /** Key decisions made */
  decisions: string[]
  /** Action items with owners */
  actionItems: string[]
  /** Unresolved questions */
  openQuestions: string[]
  /** Key takeaways */
  takeaways: string[]
}

export interface SummaryMeta {
  durationMinutes?: number
  speakers?: string[]
}

/** 纯函数:由说话人标注的转写全文构造 summary prompt(输出契约与原版一致)。 */
export function buildSummaryPrompt(transcriptText: string, meta?: SummaryMeta, context?: string): string {
  let prompt = `你是会议总结专家。基于以下会议转写（已标注说话人），生成一份完整的会后总结。\n`
  if (context && context.trim()) {
    prompt += `\n## 会前背景（帮助你更贴合本场，不要当成转写内容）\n${context.trim()}\n`
  }
  prompt += `\n## 会议转写\n${transcriptText || '（无）'}\n`
  prompt += `\n## 会议元信息
- 时长: ${(meta?.durationMinutes ?? 0).toFixed(1)} 分钟
- 说话人: ${meta?.speakers?.join(', ') || '未识别'}

## 输出要求
以 JSON 格式返回：
{
  "narrative": "完整叙事总结，300-500字，包含背景、讨论要点、结论",
  "decisions": ["已达成的决定1", "决定2"],
  "actionItems": ["行动项1（负责人+截止日期）", "行动项2"],
  "openQuestions": ["未解决的问题1", "问题2"],
  "takeaways": ["关键收获1", "收获2", "收获3"]
}
每个数组至少 1 项。如果会议中确实没有某类内容，该数组可以只包含"无"。
只返回 JSON。`
  return prompt
}

/**
 * 生成结构化纪要。返回 summary + 原始 LLM 文本(不吞错,便于后端如实展示)。
 * generateShort 在 HTTP 失败时抛错,由调用方捕获上抛。
 */
export async function generatePostMeetingSummary(params: {
  llmClient: LLMClient
  transcriptText: string
  meta?: SummaryMeta
  context?: string
  signal?: AbortSignal
}): Promise<{ summary: PostMeetingSummary | null; rawText: string; error?: string }> {
  const prompt = buildSummaryPrompt(params.transcriptText, params.meta, params.context)

  // P0-a:LLM 失败不连累已拿到的转写 —— catch 住、返回 error,绝不向上抛。
  let rawText = ''
  try {
    rawText = await params.llmClient.generateShort({
      system: '你是专业的会议总结生成器。输出格式严格为 JSON。',
      prompt,
      maxTokens: 2048,
      signal: params.signal,
    })
  } catch (err) {
    return {
      summary: null,
      rawText: '',
      error: `LLM 调用失败: ${err instanceof Error ? err.message : String(err)}`,
    }
  }

  const jsonMatch = rawText.match(/\{[\s\S]*\}/)
  if (!jsonMatch) {
    return { summary: null, rawText, error: 'LLM 响应中没有 JSON' }
  }
  try {
    const parsed = JSON.parse(jsonMatch[0]) as PostMeetingSummary
    if (!parsed.narrative || !Array.isArray(parsed.decisions)) {
      return { summary: null, rawText, error: 'JSON 结构不完整(缺 narrative/decisions)' }
    }
    return { summary: parsed, rawText }
  } catch (err) {
    return { summary: null, rawText, error: `JSON 解析失败: ${err instanceof Error ? err.message : String(err)}` }
  }
}

/** Format PostMeetingSummary as Markdown(逐字保留自原版) */
export function postSummaryToMarkdown(summary: PostMeetingSummary, meta?: { schemaName?: string; duration?: number; date?: string }): string {
  const lines: string[] = []

  if (meta?.schemaName) lines.push(`# ${meta.schemaName} — 会议总结`)
  else lines.push('# 会议总结')

  if (meta?.date || meta?.duration) {
    const parts: string[] = []
    if (meta.date) parts.push(meta.date)
    if (meta.duration) parts.push(`${meta.duration.toFixed(0)} 分钟`)
    lines.push(parts.join(' · '))
  }
  lines.push('')

  lines.push('## 总结')
  lines.push(summary.narrative)
  lines.push('')

  if (summary.decisions.length > 0 && summary.decisions[0] !== '无') {
    lines.push('## 决定事项')
    summary.decisions.forEach(d => lines.push(`- ${d}`))
    lines.push('')
  }

  if (summary.actionItems.length > 0 && summary.actionItems[0] !== '无') {
    lines.push('## 行动项')
    summary.actionItems.forEach(a => lines.push(`- [ ] ${a}`))
    lines.push('')
  }

  if (summary.openQuestions.length > 0 && summary.openQuestions[0] !== '无') {
    lines.push('## 待解决')
    summary.openQuestions.forEach(q => lines.push(`- ${q}`))
    lines.push('')
  }

  if (summary.takeaways.length > 0 && summary.takeaways[0] !== '无') {
    lines.push('## 关键收获')
    summary.takeaways.forEach(t => lines.push(`- ${t}`))
    lines.push('')
  }

  return lines.join('\n')
}
