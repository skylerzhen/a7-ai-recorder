import 'dotenv/config'
import express from 'express'
import multer from 'multer'
import { unlink } from 'node:fs/promises'
import { WebSocketServer } from 'ws'
import { processAudio, type ProcessConfig } from './process'
import type { TranscriberKind } from './transcriber'
import { StreamSession } from './stream-session'
import { LLMClient } from './llm-client'
import { LlmBrain } from './brain'

const upload = multer({ dest: 'tmp/' })
const app = express()
app.use(express.json())

function cfgFromEnv(): ProcessConfig {
  const need = (k: string): string => {
    const v = process.env[k]
    if (!v) throw new Error(`缺少环境变量 ${k}(请按 .env.example 填 .env)`)
    return v
  }
  const appId = need('XFYUN_APP_ID')
  const accessKeyId = need('XFYUN_ACCESS_KEY_ID')
  const accessKeySecret = need('XFYUN_ACCESS_KEY_SECRET')
  return {
    // 异步 /process 默认走 LFASR 批量(录音文件转写大模型版);设 TRANSCRIBER=rtasr 切回实时(基线/兜底)。
    transcriber: (process.env.TRANSCRIBER as TranscriberKind) || 'lfasr',
    xfyun: { appId, accessKeyId, accessKeySecret },
    // 批量转写复用同一套 iflyaisol WebAPI 凭据(appId/APIKey/APISecret),无需额外 key。
    ifasr: {
      appId,
      accessKeyId,
      accessKeySecret,
      roleType: Number(process.env.LFASR_ROLE_TYPE ?? 1),
      roleNum: Number(process.env.LFASR_ROLE_NUM ?? 0),
    },
    ark: {
      apiKey: need('ARK_API_KEY'),
      model: process.env.ARK_MODEL || 'doubao-pro-32k',
      baseURL: process.env.ARK_BASE_URL || 'https://ark.cn-beijing.volces.com/api/v3',
    },
    frameMs: Number(process.env.RTASR_FRAME_MS ?? 40),
  }
}

app.get('/health', (_req, res) => {
  // 不暴露密钥,只报哪些 env 已配
  res.json({
    ok: true,
    env: {
      transcriber: process.env.TRANSCRIBER || 'lfasr',
      // 批量(LFASR/Ifasr)复用 xfyun 凭据,凭据齐即就绪
      xfyun: Boolean(process.env.XFYUN_APP_ID && process.env.XFYUN_ACCESS_KEY_ID && process.env.XFYUN_ACCESS_KEY_SECRET),
      lfasr: Boolean(process.env.XFYUN_APP_ID && process.env.XFYUN_ACCESS_KEY_ID && process.env.XFYUN_ACCESS_KEY_SECRET),
      ark: Boolean(process.env.ARK_API_KEY),
      frameMs: Number(process.env.RTASR_FRAME_MS ?? 40),
    },
  })
})

// POST /process —— multipart 字段 audio,或 JSON body { path: "服务端文件路径" }(本地测试用)
app.post('/process', upload.single('audio'), async (req, res) => {
  const started = Date.now()
  const tmpPath = req.file?.path
  try {
    const inputPath = tmpPath || (req.body?.path as string | undefined)
    if (!inputPath) throw new Error('未提供音频:请用 multipart 字段 audio 上传,或 JSON body.path 给服务端路径')
    const cfg = cfgFromEnv()
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

// POST /ask —— 会中问 AI(被动):body {goal, transcript, question} → SSE 逐 token 流式「小抄」。
// 经可插拔 BrainProvider.ask(本棒 LlmBrain),不写死豆包路由。错误以 SSE error 事件回,不吞。
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
  res.setHeader('X-Accel-Buffering', 'no') // 关反代缓冲,保证逐 token 流出
  res.flushHeaders?.()

  try {
    const cfg = cfgFromEnv()
    const brain = new LlmBrain(new LLMClient(cfg.ark))
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

// POST /advise —— 会中主动提示(克制):body {goal, transcript} → JSON LiveCue(非流式,单次小决策)。
// 经 BrainProvider.advise。LLM 调用失败 → 500(错误不吞、前端可见);模型返回非 JSON → shouldPrompt:false(安静)。
app.post('/advise', async (req, res) => {
  const { goal, transcript, clientBackground } = (req.body ?? {}) as {
    goal?: string
    transcript?: string
    clientBackground?: string
  }
  try {
    const cfg = cfgFromEnv()
    const brain = new LlmBrain(new LLMClient(cfg.ark))
    const cue = await brain.advise({ goal, transcript: transcript ?? '', clientBackground })
    res.json(cue)
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    console.error('[/advise] 失败:', msg)
    res.status(500).json({ error: msg })
  }
})

// POST /summarize —— 会后纪要(快·流式):body {transcript, goal?, clientBackground?} → SSE 逐 token 吐可读 markdown。
// 契约同 /ask(data:{token} / [DONE] / {error});复用已有逐字稿出纪要(LLM-only,不重转写)。
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
  res.setHeader('X-Accel-Buffering', 'no') // 关反代缓冲,逐 token 流出
  res.flushHeaders?.()

  try {
    const cfg = cfgFromEnv()
    const brain = new LlmBrain(new LLMClient(cfg.ark))
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
    // ?fmt=pcm → 手机麦克风 PCM(s16le/16k/mono);?fmt=opus → A7 新机 88B Opus 记录;无参=mp3(A7 旧机 B0B3 走 ffmpeg)
    const q = (req.url ?? '').split('?')[1] ?? ''
    const fmtParam = new URLSearchParams(q).get('fmt')
    const fmt: 'mp3' | 'pcm' | 'opus' = fmtParam === 'pcm' ? 'pcm' : fmtParam === 'opus' ? 'opus' : 'mp3'
    session = new StreamSession(ws, cfgFromEnv(), fmt)
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
      session.onAudio(data as Buffer) // 音频 MP3 分片
    } else {
      const msg = data.toString().trim()
      if (msg === 'end' || msg.includes('"end"')) void session.end()
    }
  })
  ws.on('close', () => session?.close())
  ws.on('error', () => session?.close())
})
