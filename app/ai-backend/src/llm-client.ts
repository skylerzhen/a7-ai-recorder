/**
 * LLMClient — OpenAI-compatible LLM client.
 *
 * 逐行复用自 web-advisor/src/lib/llm-client.ts(浏览器版),Node 18+/24 全局
 * fetch / Response / TextDecoder / DOMException 均可用,故几乎原样。
 * Supports Volcengine Ark (doubao) and any OpenAI-compatible endpoint.
 */

export interface LLMConfig {
  apiKey: string
  model: string
  baseURL: string // e.g. https://ark.cn-beijing.volces.com/api/v3
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant'
  content: string
}

export class LLMClient {
  private apiKey: string
  private model: string
  private baseURL: string

  constructor(config: LLMConfig) {
    this.apiKey = config.apiKey
    this.model = config.model
    this.baseURL = config.baseURL.replace(/\/$/, '')
  }

  updateConfig(config: Partial<LLMConfig>): void {
    if (config.apiKey) this.apiKey = config.apiKey
    if (config.model) this.model = config.model
    if (config.baseURL) this.baseURL = config.baseURL.replace(/\/$/, '')
  }

  /** Streaming chat completion */
  async streamChat(params: {
    system: string
    messages: ChatMessage[]
    maxTokens?: number
    signal?: AbortSignal
    onText: (text: string) => void
    onDone: (fullText: string) => void
    onError: (error: string) => void
  }): Promise<void> {
    const messages: ChatMessage[] = [
      { role: 'system', content: params.system },
      ...params.messages,
    ]

    let response: Response
    try {
      response = await fetch(`${this.baseURL}/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${this.apiKey}`,
        },
        body: JSON.stringify({
          model: this.model,
          max_tokens: params.maxTokens ?? 1024,
          messages,
          stream: true,
          // 关闭深度思考:doubao-seed 默认先推理再吐字(首 token ~12s),disabled 后直接出字。
          thinking: { type: 'disabled' },
        }),
        signal: params.signal,
      })
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') {
        return
      }
      params.onError(`Network error: ${err instanceof Error ? err.message : String(err)}`)
      return
    }

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      params.onError(`HTTP ${response.status}: ${text.slice(0, 200)}`)
      return
    }

    const reader = response.body!.getReader()
    const decoder = new TextDecoder()
    let fullText = ''
    let buffer = ''

    try {
      while (true) {
        const { done, value } = await reader.read()
        if (done) break

        buffer += decoder.decode(value, { stream: true })
        const lines = buffer.split('\n')
        buffer = lines.pop()!

        for (const line of lines) {
          if (!line.startsWith('data: ')) continue
          const data = line.slice(6).trim()
          if (data === '[DONE]') {
            params.onDone(fullText)
            return
          }

          try {
            const chunk = JSON.parse(data)
            const text = chunk.choices?.[0]?.delta?.content || ''
            if (text) {
              fullText += text
              params.onText(text)
            }
          } catch { /* skip malformed chunks */ }
        }
      }
      params.onDone(fullText)
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') {
        return
      }
      params.onError(`Stream error: ${err instanceof Error ? err.message : String(err)}`)
    }
  }

  /** Non-streaming short generation */
  async generateShort(params: {
    system?: string
    prompt: string
    maxTokens?: number
    signal?: AbortSignal
  }): Promise<string> {
    const messages: ChatMessage[] = []
    if (params.system) messages.push({ role: 'system', content: params.system })
    messages.push({ role: 'user', content: params.prompt })

    const response = await fetch(`${this.baseURL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify({
        model: this.model,
        max_tokens: params.maxTokens ?? 1024,
        messages,
        // 关闭深度思考(纪要同病):直接出结果,省掉 seed 模型的长推理前置。
        thinking: { type: 'disabled' },
      }),
      signal: params.signal,
    })

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      throw new Error(`HTTP ${response.status}: ${text.slice(0, 200)}`)
    }

    const result = await response.json()
    return result.choices?.[0]?.message?.content?.trim() || ''
  }

  /** Structured output via function calling (tool_use) */
  async generateStructured(params: {
    system: string
    prompt: string
    tools: object[]
    toolChoice?: object
    maxTokens?: number
    signal?: AbortSignal
  }): Promise<string> {
    const response = await fetch(`${this.baseURL}/chat/completions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify({
        model: this.model,
        max_tokens: params.maxTokens ?? 2048,
        temperature: 0.3,
        messages: [
          { role: 'system', content: params.system },
          { role: 'user', content: params.prompt },
        ],
        tools: params.tools,
        tool_choice: params.toolChoice,
      }),
      signal: params.signal,
    })

    if (!response.ok) {
      const text = await response.text().catch(() => '')
      throw new Error(`HTTP ${response.status}: ${text.slice(0, 200)}`)
    }

    const result = await response.json()
    const choice = result.choices?.[0]

    // Function calling response
    if (choice?.message?.tool_calls?.[0]?.function?.arguments) {
      return choice.message.tool_calls[0].function.arguments
    }
    // Fallback to content
    if (choice?.message?.content) {
      return choice.message.content
    }
    throw new Error('No valid response from LLM')
  }
}
