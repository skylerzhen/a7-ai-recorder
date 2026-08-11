/**
 * Provider 工厂 — 路由层只调这里,不写死具体 LLM/Brain 实现。
 */

import { LlmBrain } from '../brain'
import { LLMClient } from '../llm-client'
import type { BrainProvider } from '../brain'
import type { LlmProvider, LlmProviderConfig } from './llm-provider'
import { loadLlmConfig } from './config'

export function createLlmProvider(cfg?: LlmProviderConfig): LlmProvider {
  return new LLMClient(cfg ?? loadLlmConfig())
}

export function createBrain(cfg?: LlmProviderConfig): BrainProvider {
  return new LlmBrain(createLlmProvider(cfg))
}
