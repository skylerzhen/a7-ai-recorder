# A7 AI Backend

Node/TypeScript AI 编排服务，为 A7 AI Recorder 提供批量转写、实时字幕、会中辅助和会后纪要。

## 接口

- `GET /health`：健康状态，不返回密钥。
- `POST /process`：上传音频，默认走讯飞 LFASR 批量转写，再由豆包生成结构化纪要。
- `WS /stream`：实时音频流；支持 MP3、Opus 和 PCM 输入，转发讯飞 RTASR 字幕。
- `POST /ask`：基于会中逐字稿的流式问答（SSE）。
- `POST /advise`：克制的主动会中提示。
- `POST /summarize`：基于已有逐字稿流式生成 Markdown 纪要（SSE）。

## 本地运行

要求 Node.js >= 18 和 ffmpeg。

```bash
cp .env.example .env
npm ci
npm test
npm run dev
```

关键环境变量见 `.env.example`。`.env` 严禁提交。

### 接上 OpenClaw（LLM）

OpenClaw 是 **Gateway 网关**（非个人云账号），ai-backend 通过 OpenAI 兼容 HTTP 调用它。

1. 在一台机器上安装并启动 OpenClaw Gateway（见 [OpenClaw HTTP API 文档](https://docs.openclaw.ai/gateway/openai-http-api)）
2. 开启 Chat Completions 端点（默认关闭）：
   ```bash
   openclaw config set gateway.http.endpoints.chatCompletions.enabled true
   openclaw gateway restart
   ```
3. 在 `app/ai-backend/.env` 配置：
   ```env
   OPENCLAW_GATEWAY_URL=http://127.0.0.1:18789/v1
   OPENCLAW_GATEWAY_TOKEN=<gateway.auth 里的 token>
   LLM_MODEL=openclaw:main
   LLM_PROVIDER=openai-compatible
   ```
4. 验收：`node --import tsx openclaw-check.ts`
5. 重启 ai-backend；`GET /health` 应显示 `llmViaOpenclaw: true`

讯飞 ASR（`XFYUN_*`）不变；仅 LLM（问 AI / 纪要）走 OpenClaw。

异步转写默认使用 `TRANSCRIBER=lfasr`；仅调试或回归时可切换为 `rtasr`。生产部署资产位于 `deploy/`。

## 当前状态

- 37 backend tests passing
- 已部署至 `https://a7.coolai.tech`
- 当前为内部 Alpha；生产扩大使用前必须增加调用鉴权、限流和用户配额。
