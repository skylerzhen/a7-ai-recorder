import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ifasrSign, mapIfasrResult } from '../src/ifasr'

// iflyaisol 签名:已排序 enc(k)=enc(v) join('&') → HMAC-SHA1 → base64。
// KAT:base "a=1&b=2" + secret "testsecret"(用 node:crypto 独立算一次硬编码)。
test('ifasrSign 匹配已知答案向量', () => {
  assert.equal(ifasrSign({ a: '1', b: '2' }, 'testsecret'), '9GGmgpnTm8XdeGfPFixAzI0N7V4=')
})

test('ifasrSign 与参数顺序无关(内部按 key 排序)', () => {
  assert.equal(
    ifasrSign({ b: '2', a: '1' }, 'testsecret'),
    ifasrSign({ a: '1', b: '2' }, 'testsecret'),
  )
})

function jb(st: object) {
  return { json_1best: JSON.stringify({ st }) }
}

test('mapIfasrResult: lattice/st/rt/ws/cw → 说话人+时间戳(契约不变)', () => {
  const segs = mapIfasrResult({
    lattice: [
      jb({ bg: '0', ed: '1500', rt: [{ ws: [{ cw: [{ w: '你好', wp: 'n', rl: '1' }] }, { cw: [{ w: '在吗', wp: 'n', rl: '1' }] }] }] }),
      jb({ bg: '2000', ed: '4000', rt: [{ ws: [{ cw: [{ w: '在的', wp: 'n', rl: '2' }] }] }] }),
    ],
  })
  assert.deepEqual(segs, [
    { speaker: '说话人1', text: '你好在吗', startMs: 0, endMs: 1500, isFinal: true },
    { speaker: '说话人2', text: '在的', startMs: 2000, endMs: 4000, isFinal: true },
  ])
})

test('mapIfasrResult: rl=0 沿用上一个说话人;跳过 wp=g 段标记', () => {
  const segs = mapIfasrResult({
    lattice: [
      jb({ bg: '0', ed: '500', rt: [{ ws: [{ cw: [{ w: '甲', rl: '2' }] }] }] }),
      jb({ bg: '500', ed: '900', rt: [{ ws: [{ cw: [{ w: '续', rl: '0' }] }, { cw: [{ w: '段', wp: 'g', rl: '0' }] }] }] }),
    ],
  })
  assert.equal(segs[1].speaker, '说话人2') // rl=0 沿用上一段
  assert.equal(segs[1].text, '续') // wp=g 跳过
})

test('mapIfasrResult: 接受 cn.st 嵌套 + 整体 JSON 字符串', () => {
  const raw = JSON.stringify({
    lattice: [{ json_1best: JSON.stringify({ cn: { st: { bg: '0', ed: '100', rt: [{ ws: [{ cw: [{ w: '喂', rl: '1' }] }] }] } } }) }],
  })
  const segs = mapIfasrResult(raw)
  assert.equal(segs.length, 1)
  assert.equal(segs[0].text, '喂')
  assert.equal(segs[0].endMs, 100)
})

test('mapIfasrResult: 非法/空 → []', () => {
  assert.deepEqual(mapIfasrResult('not json'), [])
  assert.deepEqual(mapIfasrResult({}), [])
})
