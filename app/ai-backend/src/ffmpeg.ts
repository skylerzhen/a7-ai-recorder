import { spawn } from 'node:child_process'

/**
 * 用 ffmpeg 把任意输入音频(A7 是 MP3 16kHz/mono/32kbps)解码成
 * **PCM s16le / 16000Hz / mono**(讯飞 RTASR 要求),返回完整 Buffer。
 * 等价命令:`ffmpeg -i in -f s16le -ar 16000 -ac 1 -`
 */
export function decodeToPcm16kMono(inputPath: string): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const args = [
      '-hide_banner', '-loglevel', 'error',
      '-i', inputPath,
      '-f', 's16le', // PCM signed 16-bit little-endian
      '-ar', '16000', // 16kHz
      '-ac', '1', // mono
      '-',
    ]
    const ff = spawn('ffmpeg', args)
    const out: Buffer[] = []
    const err: Buffer[] = []
    ff.stdout.on('data', (d: Buffer) => out.push(d))
    ff.stderr.on('data', (d: Buffer) => err.push(d))
    ff.on('error', (e) =>
      reject(new Error(`ffmpeg 启动失败(是否已安装 ffmpeg?): ${e.message}`)))
    ff.on('close', (code) => {
      if (code === 0) resolve(Buffer.concat(out))
      else reject(new Error(`ffmpeg 退出码 ${code}: ${Buffer.concat(err).toString('utf8').slice(0, 500)}`))
    })
  })
}

/** PCM s16le/16k/mono 的时长(秒)= 字节数 / (16000 采样 × 2 字节)。 */
export function pcmDurationSec(pcmBytes: number): number {
  return pcmBytes / (16000 * 2)
}

/** 用 ffprobe 取音频时长(秒);供 LFASR 上传的 duration 参数(失败抛出,调用方兜底)。 */
export function probeDurationSec(inputPath: string): Promise<number> {
  return new Promise((resolve, reject) => {
    const ff = spawn('ffprobe', [
      '-v', 'error',
      '-show_entries', 'format=duration',
      '-of', 'default=noprint_wrappers=1:nokey=1',
      inputPath,
    ])
    let out = ''
    let err = ''
    ff.stdout.on('data', (d: Buffer) => (out += d.toString()))
    ff.stderr.on('data', (d: Buffer) => (err += d.toString()))
    ff.on('error', (e) => reject(new Error(`ffprobe 启动失败: ${e.message}`)))
    ff.on('close', (code) =>
      code === 0
        ? resolve(Number.parseFloat(out.trim()) || 0)
        : reject(new Error(`ffprobe 退出码 ${code}: ${err.slice(0, 200)}`)))
  })
}
