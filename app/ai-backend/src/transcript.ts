/** RTASR 的 you/them 盲分离 → 展示用说话人标签。 */
export function speakerLabel(speaker: 'you' | 'them'): string {
  return speaker === 'you' ? '说话人1' : '说话人2'
}

/**
 * 把(已标注说话人的)分段 final 拼成给 LLM 的转写全文:
 * 连续同一说话人合并为一行 `[说话人X] 文本…`,空白段跳过。
 */
export function assembleTranscript(entries: { speaker: string; text: string }[]): string {
  const lines: string[] = []
  let curSpeaker: string | null = null
  let curText = ''
  const flush = () => {
    if (curSpeaker !== null && curText.trim()) {
      lines.push(`[${curSpeaker}] ${curText.trim()}`)
    }
    curText = ''
  }
  for (const e of entries) {
    const t = e.text.trim()
    if (!t) continue
    if (e.speaker !== curSpeaker) {
      flush()
      curSpeaker = e.speaker
    }
    curText += t
  }
  flush()
  return lines.join('\n')
}
