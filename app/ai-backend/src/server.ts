import 'dotenv/config'
import express from 'express'
import multer from 'multer'
import { unlink } from 'node:fs/promises'
import { WebSocketServer } from 'ws'
import { processAudio } from './process'
import { StreamSession } from './stream-session'
import { loadAppConfig, loadLlmConfig, healthEnvSnapshot } from './providers/config'
import { createBrain } from './providers/factory'

const upload = multer({ dest: 'tmp/' })
const app = express()
app.use(express.json())

function brainForRequest(req: express.Request) {
  const modelOverride = (req.body?.model as string | undefined)?.trim()
  return createBrain(loadLlmConfig(modelOverride || undefined))
}

app.get('/health', (_req, res) => {
  res.json({ ok: true, env: healthEnvSnapshot() })
})

// POST /process —— multipart 字段 audio,或 JSON body { path: "服务端文件路径" }(本地测试用)
app.post('/process', upload.single('audio'), async (req, res) => {
  const started = Date.now()
  const tmpPath = req.file?.path
  try {
    const inputPath = tmpPath || (req.body?.path as string | undefined)
    if (!inputPath) throw new Error('未提供音频:请用 multipart 字段 audio 上传,或 JSON body.path 给服务端路径')
    const cfg = loadAppConfig()
    console.log(`[/process] 开始处理 ${inputPath} (frameMs=${cfg.frameMs})`)
    const result = await processAudio(inputPath, cfg)
    console.log(`[/process] 完成 in ${Date.now() - started}ms, 段=${result.transcript.length}`)
    res.json(result)
  } catch (err) {
    console.error('[/process] 失败:', err)
    res.status(500).json({ error: err instanceof Error ? err.message : String(err) })
  } finally {
    if (tmpPath) {
      unlink(tmpPath).catch(() => {})
    }
  }
})

// POST /ask —— 会中问 AI(被动):body {goal, transcript, question, model?} → SSE 逐 token 流式「小抄」。
app.post('/ask', async (req, res) => {
  const { goal, transcript, question, clientBackground } = (req.body ?? {}) as {
    goal?: string
    transcript?: string
    question?: string
    clientBackground?: string
  }
  if (!question || !question.trim()) {
    res.status(400).json({ error: '缺少 question' })
    return
  }
  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8')
  res.setHeader('Cache-Control', 'no-cache, no-transform')
  res.setHeader('Connection', 'keep-alive')
  res.setHeader('X-Accel-Buffering', 'no')
  res.flushHeaders?.()

  try {
    const brain = brainForRequest(req)
    for await (const token of brain.ask(
      { goal, transcript: transcript ?? '', clientBackground },
      question,
    )) {
      res.write(`data: ${JSON.stringify({ token })}\n\n`)
    }
    res.write('data: [DONE]\n\n')
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[/ask] 失败:', msg)
    res.write(`data: ${JSON.stringify({ error: msg })}\n\n`)
  } finally {
    res.end()
  }
})

// POST /advise —— 会中主动提示(克制):body {goal, transcript, model?} → JSON LiveCue。
app.post('/advise', async (req, res) => {
  const { goal, transcript, clientBackground } = (req.body ?? {}) as {
    goal?: string
    transcript?: string
    clientBackground?: string
  }
  try {
    const brain = brainForRequest(req)
    const cue = await brain.advise({ goal, transcript: transcript ?? '', clientBackground })
    res.json(cue)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[/advise] 失败:', msg)
    res.status(500).json({ error: msg })
  }
})

// POST /summarize —— 会后纪要(快·流式):body {transcript, goal?, clientBackground?, model?} → SSE。
app.post('/summarize', async (req, res) => {
  const { transcript, goal, clientBackground } = (req.body ?? {}) as {
    transcript?: string
    goal?: string
    clientBackground?: string
  }
  if (!transcript || !transcript.trim()) {
    res.status(400).json({ error: '缺少 transcript' })
    return
  }
  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8')
  res.setHeader('Cache-Control', 'no-cache, no-transform')
  res.setHeader('Connection', 'keep-alive')
  res.setHeader('X-Accel-Buffering', 'no')
  res.flushHeaders?.()

  try {
    const brain = brainForRequest(req)
    for await (const token of brain.summarize({ transcript, goal, clientBackground })) {
      res.write(`data: ${JSON.stringify({ token })}\n\n`)
    }
    res.write('data: [DONE]\n\n')
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[/summarize] 失败:', msg)
    res.write(`data: ${JSON.stringify({ error: msg })}\n\n`)
  } finally {
    res.end()
  }
})

const port = Number(process.env.PORT ?? 8787)
const server = app.listen(port, () => {
  console.log(`A7 AI backend → http://localhost:${port}  (POST /process, GET /health, WS /stream)`)
})

// ===== 近实时字幕:WebSocket /stream =====
const wss = new WebSocketServer({ server, path: '/stream' })
wss.on('connection', (ws, req) => {
  let session: StreamSession | null = null
  try {
    const q = (req.url ?? '').split('?')[1] ?? ''
    const fmtParam = new URLSearchParams(q).get('fmt')
    const fmt: 'mp3' | 'pcm' | 'opus' = fmtParam === 'pcm' ? 'pcm' : fmtParam === 'opus' ? 'opus' : 'mp3'
    session = new StreamSession(ws, loadAppConfig(), fmt)
    void session.start()
  } catch (err) {
    try {
      ws.send(JSON.stringify({ type: 'error', error: err instanceof Error ? err.message : String(err) }))
    } catch {/* ignore */}
    ws.close()
    return
  }
  ws.on('message', (data, isBinary) => {
    if (!session) return
    if (isBinary) {
      session.onAudio(data as Buffer)
    } else {
      const msg = data.toString().trim()
      if (msg === 'end' || msg.includes('"end"')) void session.end()
    }
  })
  ws.on('close', () => session?.close())
  ws.on('error', () => session?.close())
})
