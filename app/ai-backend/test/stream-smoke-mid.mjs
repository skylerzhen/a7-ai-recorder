// Bug-2 验证:从 live_b3.mp3 的「帧中间」(offset 777)开始喂,模拟真机 B0B3 帧中间起步。
// 期望:后端用 -f mp3 + 裁同步起步,日志不刷 Header missing,字幕照常出。
import WebSocket from 'ws'
import { readFileSync } from 'node:fs'

const OFFSET = 777 // 故意从帧中间起步
const mp3 = readFileSync(new URL('./fixtures/live_b3.mp3', import.meta.url)).subarray(OFFSET)
const ws = new WebSocket('ws://localhost:8787/stream')
let first = 0
const t0 = Date.now()

ws.on('open', () => console.log(`[mid] connected, 从 offset=${OFFSET} 起步喂`))
ws.on('message', (data) => {
  const m = JSON.parse(data.toString())
  if (m.type === 'ready') stream()
  else if (m.type === 'transcript') {
    if (!first) first = Date.now() - t0
    if (m.isFinal) console.log(`[+${Date.now() - t0}ms FINAL][${m.speaker}] ${m.text}`)
  } else if (m.type === 'status') console.log('[status]', m.status, m.detail || '')
  else if (m.type === 'error') console.log('[ERROR]', m.error)
  else if (m.type === 'done') { console.log(`[mid] done frames=${m.frames} 首字幕=${first}ms`); ws.close() }
})
ws.on('close', () => process.exit(0))
ws.on('error', (e) => { console.error('[mid] ws error', e.message); process.exit(1) })

async function stream() {
  const CHUNK = 1024
  for (let i = 0; i < mp3.length; i += CHUNK) {
    ws.send(mp3.subarray(i, i + CHUNK))
    await new Promise((r) => setTimeout(r, 200))
  }
  ws.send('end')
}
