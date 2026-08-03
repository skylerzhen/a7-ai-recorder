// /stream 流式冒烟:把真 A7 录音样本 live_b3.mp3 按 ~实时节奏分片喂 WS,
// 打印边收边出的字幕(interim/final)。需要后端在 :8787 跑着(真 key)。
import WebSocket from 'ws'
import { readFileSync } from 'node:fs'

const mp3 = readFileSync(new URL('./fixtures/live_b3.mp3', import.meta.url))
const ws = new WebSocket('ws://localhost:8787/stream')
let firstCaptionAt = 0
const t0 = Date.now()
const finals = []

ws.on('open', () => console.log('[smoke] connected, waiting ready...'))
ws.on('message', (data) => {
  const msg = JSON.parse(data.toString())
  if (msg.type === 'ready') {
    console.log('[smoke] ready → 流式喂 live_b3.mp3 (~5KB/s, 边收)')
    streamAudio()
  } else if (msg.type === 'transcript') {
    if (!firstCaptionAt) firstCaptionAt = Date.now() - t0
    console.log(`[+${Date.now() - t0}ms ${msg.isFinal ? 'FINAL ' : 'interim'}] [${msg.speaker}] ${msg.text}`)
    if (msg.isFinal) finals.push(msg)
  } else if (msg.type === 'status') {
    console.log('[status]', msg.status, msg.detail || '')
  } else if (msg.type === 'error') {
    console.log('[ERROR]', msg.error)
  } else if (msg.type === 'done') {
    console.log(`[smoke] done frames=${msg.frames} finals=${finals.length} 首字幕=${firstCaptionAt}ms`)
    ws.close()
  }
})
ws.on('close', () => { console.log('[smoke] closed'); process.exit(0) })
ws.on('error', (e) => { console.error('[smoke] ws error', e.message); process.exit(1) })

async function streamAudio() {
  const CHUNK = 1024
  for (let i = 0; i < mp3.length; i += CHUNK) {
    ws.send(mp3.subarray(i, i + CHUNK))
    await new Promise((r) => setTimeout(r, 200)) // ~5KB/s,贴近 B0B3 实时
  }
  console.log(`[smoke] 音频发完 (${mp3.length}B),发 end`)
  ws.send('end')
}
