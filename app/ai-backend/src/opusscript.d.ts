// opusscript 无官方类型;只声明本项目用到的部分(纯 JS/WASM libopus,免原生构建)。
declare module 'opusscript' {
  export default class OpusScript {
    constructor(sampleRate: number, channels: number, application?: number)
    decode(data: Buffer): Buffer
    encode(pcm: Buffer, frameSize: number): Buffer
    delete(): void
  }
}
