/**
 * 从环境变量加载后端配置。LLM 优先读 LLM_*;ARK_* 保留向后兼容。
 */

import type { IfasrCfg } from '../ifasr'
import type { TranscriberKind } from '../transcriber'
import type { LlmProviderConfig, LlmProviderKind } from './llm-provider'
import { inferLlmProviderKind } from './llm-provider'

export interface AppConfig {
  transcriber: TranscriberKind
  xfyun: { appId: string; accessKeyId: string; accessKeySecret: string }
  ifasr: IfasrCfg
  llm: LlmProviderConfig
  frameMs: number
}

function envFirst(...keys: string[]): string | undefined {
  for (const k of keys) {
    const v = process.env[k]
    if (v) return v
  }
  return undefined
}

function needEnv(...keys: string[]): string {
  const v = envFirst(...keys)
  if (!v) {
    throw new Error(`缺少环境变量 ${keys.join(' 或 ')}(请按 .env.example 填 .env)`)
  }
  return v
}

function parseLlmProvider(raw?: string): LlmProviderKind | undefined {
  if (!raw) return undefined
  if (raw === 'ark-doubao' || raw === 'openai-compatible') return raw
  throw new Error(`无效的 LLM_PROVIDER: ${raw}(可选 ark-doubao / openai-compatible)`)
}

/** 读取 LLM 配置;可选 modelOverride 用于请求级切模型。 */
export function loadLlmConfig(modelOverride?: string): LlmProviderConfig {
  const apiKey = needEnv('LLM_API_KEY', 'ARK_API_KEY')
  const baseURL =
    envFirst('LLM_BASE_URL', 'ARK_BASE_URL') || 'https://ark.cn-beijing.volces.com/api/v3'
  const model = modelOverride || envFirst('LLM_MODEL', 'ARK_MODEL') || 'doubao-pro-32k'
  const explicit = parseLlmProvider(process.env.LLM_PROVIDER)
  return {
    apiKey,
    model,
    baseURL,
    provider: inferLlmProviderKind(baseURL, explicit),
  }
}

export function loadAppConfig(): AppConfig {
  const appId = needEnv('XFYUN_APP_ID')
  const accessKeyId = needEnv('XFYUN_ACCESS_KEY_ID')
  const accessKeySecret = needEnv('XFYUN_ACCESS_KEY_SECRET')
  return {
    transcriber: (process.env.TRANSCRIBER as TranscriberKind) || 'lfasr',
    xfyun: { appId, accessKeyId, accessKeySecret },
    ifasr: {
      appId,
      accessKeyId,
      accessKeySecret,
      roleType: Number(process.env.LFASR_ROLE_TYPE ?? 1),
      roleNum: Number(process.env.LFASR_ROLE_NUM ?? 0),
    },
    llm: loadLlmConfig(),
    frameMs: Number(process.env.RTASR_FRAME_MS ?? 40),
  }
}

/** /health 用:不暴露密钥,只报配置就绪情况。 */
export function healthEnvSnapshot() {
  return {
    transcriber: process.env.TRANSCRIBER || 'lfasr',
    xfyun: Boolean(
      process.env.XFYUN_APP_ID && process.env.XFYUN_ACCESS_KEY_ID && process.env.XFYUN_ACCESS_KEY_SECRET,
    ),
    lfasr: Boolean(
      process.env.XFYUN_APP_ID && process.env.XFYUN_ACCESS_KEY_ID && process.env.XFYUN_ACCESS_KEY_SECRET,
    ),
    llm: Boolean(envFirst('LLM_API_KEY', 'ARK_API_KEY')),
    llmProvider: process.env.LLM_PROVIDER || '(auto)',
    llmModel: envFirst('LLM_MODEL', 'ARK_MODEL') || 'doubao-pro-32k',
    frameMs: Number(process.env.RTASR_FRAME_MS ?? 40),
  }
}
