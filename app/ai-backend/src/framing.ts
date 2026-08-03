/** 把 PCM(s16le)切成固定大小帧;末帧不足则补零。讯飞 RTASR 要 1280B/帧(=40ms@16k)。 */
export function chunkPcmFrames(pcm: Buffer, frameSize = 1280): Buffer[] {
  const frames: Buffer[] = []
  for (let off = 0; off < pcm.length; off += frameSize) {
    const slice = pcm.subarray(off, off + frameSize)
    if (slice.length === frameSize) {
      frames.push(Buffer.from(slice))
    } else {
      const padded = Buffer.alloc(frameSize) // 末帧补零(静音)
      slice.copy(padded)
      frames.push(padded)
    }
  }
  return frames
}
