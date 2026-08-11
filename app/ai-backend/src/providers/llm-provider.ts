/**
 * LLM Provider 抽象 — 任何 OpenAI 兼容端点(豆包/方舟、OpenClaw、OpenAI 等)均实现此接口。
 */

export type LlmProviderKind = 'openai-compatible' | 'ark-doubao'

export interface LlmProviderConfig {
  apiKey: string
  model: string
  baseURL: string
  /** 控制 provider 专有扩展(如豆包 thinking 字段);未设则按 baseURL 推断。 */
  provider?: LlmProviderKind
}

/** @deprecated 保留别名,便于旧代码迁移 */
export type LLMConfig = LlmProviderConfig

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export interface LlmProvider {
  streamChat(params: {
    system: string
    messages: ChatMessage[]
    maxTokens?: number
    signal?: AbortSignal
    onText: (text: string) => void
    onDone: (fullText: string) => void
    onError: (error: string) => void
  }): Promise<void>

  generateShort(params: {
    system?: string
    prompt: string
    maxTokens?: number
    signal?: AbortSignal
  }): Promise<string>

  generateStructured(params: {
    system: string
    prompt: string
    tools: object[]
    toolChoice?: object
    maxTokens?: number
    signal?: AbortSignal
  }): Promise<string>
}

/** 按 baseURL 推断 provider kind(豆包/方舟需 thinking 扩展)。 */
export function inferLlmProviderKind(baseURL: string, explicit?: LlmProviderKind): LlmProviderKind {
  if (explicit) return explicit
  const url = baseURL.toLowerCase()
  if (url.includes('volces.com') || url.includes('volcengine')) return 'ark-doubao'
  return 'openai-compatible'
}
