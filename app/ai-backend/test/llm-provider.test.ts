import { test } from 'node:test'
import assert from 'node:assert/strict'
import { inferLlmProviderKind } from '../src/providers/llm-provider'

test('inferLlmProviderKind:volces → ark-doubao', () => {
  assert.equal(inferLlmProviderKind('https://ark.cn-beijing.volces.com/api/v3'), 'ark-doubao')
})

test('inferLlmProviderKind:openclaw → openai-compatible', () => {
  assert.equal(inferLlmProviderKind('https://openclaw-api.com/v1'), 'openai-compatible')
})

test('inferLlmProviderKind:explicit override', () => {
  assert.equal(
    inferLlmProviderKind('https://openclaw-api.com/v1', 'ark-doubao'),
    'ark-doubao',
  )
})
