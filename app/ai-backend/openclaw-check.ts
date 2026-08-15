/**
 * 验收 OpenClaw Gateway 是否可被 ai-backend 调用。
 * 用法: node --import tsx openclaw-check.ts
 * 需 .env 里配 OPENCLAW_GATEWAY_URL + OPENCLAW_GATEWAY_TOKEN(或 LLM_API_KEY)。
 */
import 'dotenv/config'
import { loadLlmConfig } from './src/providers/config'
import { createLlmProvider } from './src/providers/factory'

async function main() {
  const cfg = loadLlmConfig()
  console.log('LLM baseURL:', cfg.baseURL)
  console.log('LLM model  :', cfg.model)
  console.log('provider   :', cfg.provider)

  const llm = createLlmProvider(cfg)
  const text = await llm.generateShort({
    system: '你是测试助手,只回复一行确认语。',
    prompt: '回复: OpenClaw 已连通',
    maxTokens: 64,
  })
  console.log('\n✅ OpenClaw 响应:', text)
}

main().catch((e) => {
  console.error('\n❌ OpenClaw 连通失败:', e instanceof Error ? e.message : e)
  console.error('\n排查:')
  console.error('  1. openclaw gateway 是否在跑? (默认 http://127.0.0.1:18789)')
  console.error('  2. chatCompletions 是否已开启?')
  console.error('     openclaw config set gateway.http.endpoints.chatCompletions.enabled true')
  console.error('     openclaw gateway restart')
  console.error('  3. OPENCLAW_GATEWAY_TOKEN 是否与 gateway.auth 一致?')
  process.exit(1)
})
