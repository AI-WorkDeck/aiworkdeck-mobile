#!/usr/bin/env node
// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// scripts/check-palette.mjs — 配色体系闸门。用法：node scripts/check-palette.mjs [--root DIR] [-v]
//
// 五道检查：
//   ① 本仓 design/tokens/awd-palette.json 的 sha256 等于 EXPECTED_SHA256。
//      三仓靠这个常量锁住「色源逐字节相同」；改配色时三仓同步更新这个常量。
//   ② contract/tokens.json 的每个色值等于色源 roles 里对应的语义角色（下方 ROLE_MAP）。
//      本仓的令牌真源是 contract/tokens.json（四端生成物由它派生），ROLE_MAP 是它与色源之间的那根线。
//   ③ 跑一遍 contract/tools/lib.mjs 的 outputs()，与入库生成物逐字节比对，不一致就打 diff 并非零退出。
//   ④ 小程序 tokens.wxss 与 iOS Tokens.swift 的颜色令牌逐值对应（解析两边的生成物，按令牌名对齐比色）。
//   ⑤ 按 WCAG 2.1 相对亮度公式复算色源 contrast 块声明的每一项（容差 0.05），
//      并对本仓令牌跑最低对比度闸门（正文/强调 4.5，控件与装饰 3.0）。
//
// 不依赖任何构建产物，node 直接跑。

import { readFileSync, existsSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadContract, outputs } from '../contract/tools/lib.mjs'

const EXPECTED_SHA256 = '2eaa53a9d1a6437f587261b68ad2a372ad1aef9100c79551445089aaf5c2ba64'

const args = process.argv.slice(2)
const ri = args.indexOf('--root')
const ROOT = resolve(ri >= 0 ? args[ri + 1] : join(dirname(fileURLToPath(import.meta.url)), '..'))
const VERBOSE = args.includes('-v') || args.includes('--verbose')

const PALETTE_REL = 'design/tokens/awd-palette.json'

/** contract/tokens.json 的每个色 → 色源 roles 里的角色。左边是本仓令牌名（公开契约，不改名），右边是语义角色。 */
const ROLE_MAP = {
  L: {
    bg: 'light/surface',            // 页面底：新体系里近白的暖面
    sunken: 'light/bg',             // 凹陷区：比页面底更深一档的玉脂白
    fg: 'light/text',
    fgMuted: 'light/text-2',
    fgFaint: 'light/text-3',
    rule: 'light/border-subtle',
    ruleStrong: 'light/border',
    accent: 'light/accent',         // 墨竹青，替掉旧藏青 #1E3A8A
    accentWash: 'light/accent-soft',
  },
  D: {
    bg: 'dark/bg',
    surface: 'dark/surface',
    fg: 'dark/text',
    fgMuted: 'dark/text-2',
    rule: 'dark/glass-border',       // 深色发丝线，仍是 10% 白，值未变
  },
  // 取证状态色：保留色相家族（黄/蓝/绿/红），取色源里同族、且够得上其实际用法对比度的那一档。
  S: {
    waiting: 'light/warning-text',   // --st-waiting 在 queue.wxss 里当正文色用，warning 本体只有 3.2:1
    moving: 'light/info',
    arrived: 'light/accent',
    failed: 'light/danger',          // 浅底 5.2、深底 3.4，浅深两处都用得起
    waitingOnDark: 'dark/warning',
    movingOnDark: 'dark/info-text',  // T.S.movingOnDark 在 HomeView 里当正文色用，info 本体只有 4.4:1
    arrivedOnDark: 'dark/accent-text', // 竹月青，深色模式的强调文字色
  },
}

/** 色源 contrast 块的键 → [前景角色, 背景角色]。'#RRGGBB' 直写表示固定色。 */
const CONTRAST_PAIRS = {
  'light/text-on-bg': ['light/text', 'light/bg'],
  'light/text-2-on-bg': ['light/text-2', 'light/bg'],
  'light/text-2-on-surface': ['light/text-2', 'light/surface'],
  'light/accent-on-bg': ['light/accent', 'light/bg'],
  'light/textOnAccent-on-accent': ['light/text-on-accent', 'light/accent'],
  'light/gold-text-on-bg': ['light/gold-text', 'light/bg'],
  'light/textOnMint-on-mint': ['light/text-on-mint', 'light/mint'],
  'light/danger-on-white': ['light/danger', '#FFFFFF'],
  'dark/text-on-bg': ['dark/text', 'dark/bg'],
  'dark/text-2-on-bg': ['dark/text-2', 'dark/bg'],
  'dark/accent-text-on-bg': ['dark/accent-text', 'dark/bg'],
  'dark/gold-text-on-bg': ['dark/gold-text', 'dark/bg'],
}

/** 本仓令牌自己的对比度闸门：[前景, 背景, 下限, 说明] */
const TOKEN_GATES = [
  ['L.fg', 'L.bg', 4.5, '浅底正文'],
  ['L.fg', 'L.sunken', 4.5, '凹陷区正文'],
  ['L.fgMuted', 'L.bg', 4.5, '浅底次级文字'],
  ['L.fgMuted', 'L.sunken', 4.5, '凹陷区次级文字'],
  ['L.accent', 'L.bg', 4.5, '浅底强调'],
  ['#FFFFFF', 'L.accent', 4.5, '强调面上的白字'],
  ['D.fg', 'D.bg', 4.5, '深底正文'],
  ['D.fgMuted', 'D.bg', 4.5, '深底次级文字'],
  ['D.fg', 'D.surface', 4.5, '深色卡片正文'],
  ['S.waiting', 'L.bg', 4.5, '等待态文字'],
  ['S.moving', 'L.bg', 4.5, '传输态文字'],
  ['S.arrived', 'L.bg', 4.5, '到达态文字'],
  ['S.failed', 'L.bg', 4.5, '失败态文字'],
  ['S.failed', 'D.bg', 3.0, '深底失败态标记'],
  ['S.waitingOnDark', 'D.bg', 4.5, '深底等待态文字'],
  ['S.movingOnDark', 'D.bg', 4.5, '深底传输态文字'],
  ['S.arrivedOnDark', 'D.bg', 4.5, '深底到达态文字'],
  ['L.ruleStrong', 'L.bg', 1.2, '浅底重分隔线'],
]

// ---------- 颜色与对比度 ----------
function parseColor(v) {
  const s = String(v).trim()
  const m = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/.exec(s)
  if (m) return { r: +m[1], g: +m[2], b: +m[3], a: m[4] === undefined ? 1 : +m[4] }
  const h = /^#([0-9a-fA-F]{6})$/.exec(s)
  if (h) {
    const n = parseInt(h[1], 16)
    return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255, a: 1 }
  }
  return null
}
const sameColor = (a, b) => {
  const x = parseColor(a), y = parseColor(b)
  if (!x || !y) return false
  return x.r === y.r && x.g === y.g && x.b === y.b && Math.abs(x.a - y.a) < 1e-6
}
const chan = (n) => {
  const c = n / 255
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}
const luminance = (c) => 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b)
function contrast(fg, bg) {
  const f = parseColor(fg), b = parseColor(bg)
  if (!f || !b) return null
  if (f.a < 1) return null // 半透明色压在什么底上不确定，不参与对比度判定
  const l1 = luminance(f), l2 = luminance(b)
  const [hi, lo] = l1 >= l2 ? [l1, l2] : [l2, l1]
  return (hi + 0.05) / (lo + 0.05)
}
const round2 = (n) => Math.round(n * 100) / 100

// ---------- 主体 ----------
const problems = []
const notes = []
const ok = (s) => { if (VERBOSE) console.log('  ' + s) }

const palettePath = join(ROOT, PALETTE_REL)
if (!existsSync(palettePath)) {
  console.error(`✗ 找不到色源 ${PALETTE_REL}`)
  process.exit(1)
}
const paletteRaw = readFileSync(palettePath)
const palette = JSON.parse(paletteRaw.toString('utf8'))

// ① 色源指纹
console.log('① 色源指纹')
const actualSha = createHash('sha256').update(paletteRaw).digest('hex')
if (actualSha !== EXPECTED_SHA256) {
  problems.push(
    `${PALETTE_REL} 的 sha256 不是三仓约定的值：\n` +
    `    实际 ${actualSha}\n    期望 ${EXPECTED_SHA256}\n` +
    `    要么这份副本漂了（从别的仓拷回来），要么配色真的改了（三仓一起更新 EXPECTED_SHA256）`
  )
} else ok(`sha256 ${actualSha} ✓（${palette.name} ${palette.version}）`)

// 角色取值
const roleValue = (ref) => {
  if (ref.startsWith('#') || ref.startsWith('rgb')) return ref
  const [mode, ...rest] = ref.split('/')
  const key = rest.join('/')
  const v = palette.roles?.[mode]?.[key]
  if (v === undefined) problems.push(`色源里没有角色 ${ref}`)
  return v
}

// ② 令牌值 = 色源角色
console.log('② contract/tokens.json 的色值对齐色源角色')
const tokens = JSON.parse(readFileSync(join(ROOT, 'contract', 'tokens.json'), 'utf8'))
for (const [grp, map] of Object.entries(ROLE_MAP)) {
  const declared = Object.keys(tokens[grp] ?? {}).filter((k) => parseColor(tokens[grp][k]))
  for (const k of declared) {
    if (!(k in map)) problems.push(`tokens.json 的 ${grp}.${k} 是个颜色但 ROLE_MAP 里没给它定角色：新令牌要先在色源里选定语义`)
  }
  for (const [k, ref] of Object.entries(map)) {
    const have = tokens[grp]?.[k]
    const want = roleValue(ref)
    if (have === undefined) { problems.push(`tokens.json 缺令牌 ${grp}.${k}`); continue }
    if (want === undefined) continue
    if (!sameColor(have, want)) problems.push(`${grp}.${k} = ${have}，但角色 ${ref} 是 ${want}`)
    else ok(`${grp}.${k} = ${have}  ← ${ref}`)
  }
}

// ③ 生成物未过期
console.log('③ 四端生成物与色源派生的令牌一致')
const c = loadContract(ROOT)
let stale = 0
for (const [rel, content] of outputs(c)) {
  const abs = join(ROOT, rel)
  const onDisk = existsSync(abs) ? readFileSync(abs, 'utf8') : null
  if (onDisk === content) continue
  stale++
  if (onDisk === null) { problems.push(`生成物缺失：${rel}`); continue }
  const a = onDisk.split('\n'), b = content.split('\n')
  const diff = []
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (a[i] !== b[i]) diff.push(`      ${i + 1}  入库 ${JSON.stringify(a[i] ?? null)}\n      ${i + 1}  应为 ${JSON.stringify(b[i] ?? null)}`)
    if (diff.length >= 8) { diff.push('      …'); break }
  }
  problems.push(`生成物过期：${rel}（跑 npm run contract:gen）\n${diff.join('\n')}`)
}
if (!stale) ok(`${outputs(c).size} 个生成物逐字节一致 ✓`)

// ④ 小程序与 iOS 逐值对应
console.log('④ tokens.wxss 与 Tokens.swift 逐值对应')
const wxssText = readFileSync(join(ROOT, 'miniprogram', 'styles', 'tokens.wxss'), 'utf8')
const swiftText = readFileSync(join(ROOT, 'ios', 'Sources', 'Contract', 'Tokens.swift'), 'utf8')

const wxssVars = new Map()
for (const m of wxssText.matchAll(/^\s*--([a-z0-9-]+):\s*([^;]+);/gim)) wxssVars.set(m[1], m[2].trim())

const swiftVals = new Map() // "L.accent" -> 色值字符串
{
  let cur = null
  for (const line of swiftText.split('\n')) {
    const e = /^\s{4}enum ([A-Za-z]+) \{/.exec(line)
    if (e) { cur = e[1]; continue }
    if (!cur) continue
    const hx = /^\s*static let ([A-Za-z0-9]+) = Color\(hex: 0x([0-9A-Fa-f]{6})\)/.exec(line)
    if (hx) { swiftVals.set(`${cur}.${hx[1]}`, '#' + hx[2]); continue }
    const rgba = /^\s*static let ([A-Za-z0-9]+) = Color\(\.sRGB, red: ([\d.]+), green: ([\d.]+), blue: ([\d.]+), opacity: ([\d.]+)\)/.exec(line)
    if (rgba) {
      const to255 = (s) => Math.round(parseFloat(s) * 255)
      swiftVals.set(`${cur}.${rgba[1]}`, `rgba(${to255(rgba[2])}, ${to255(rgba[3])}, ${to255(rgba[4])}, ${parseFloat(rgba[5])})`)
    }
  }
}

let pairs = 0
const parity = []
for (const grp of ['L', 'D', 'S']) {
  for (const k of Object.keys(tokens[grp] ?? {})) {
    const wxssName = tokens.wxssNames?.[grp]?.[k]
    if (!wxssName) { problems.push(`tokens.json 的 ${grp}.${k} 没有 wxssNames 映射：小程序侧会少一个变量，两端就不再逐值对应`); continue }
    const w = wxssVars.get(wxssName)
    const s = swiftVals.get(`${grp}.${k}`)
    if (w === undefined) { problems.push(`tokens.wxss 里没有 --${wxssName}（对应 ${grp}.${k}）`); continue }
    if (s === undefined) { problems.push(`Tokens.swift 里没有 T.${grp}.${k}（对应 --${wxssName}）`); continue }
    if (!sameColor(w, s)) { problems.push(`两端不同值：--${wxssName} = ${w}，T.${grp}.${k} = ${s}`); continue }
    pairs++
    parity.push(`    --${wxssName.padEnd(14)} = ${String(w).padEnd(26)} = T.${grp}.${k}`)
  }
}
if (VERBOSE) console.log(parity.join('\n'))
ok(`${pairs} 个颜色令牌两端逐值一致 ✓`)
if (!VERBOSE) console.log(`    ${pairs} 个颜色令牌两端逐值一致`)

// ⑤ 对比度
console.log('⑤ 对比度复算与闸门')
const declaredKeys = Object.keys(palette.contrast ?? {}).filter((k) => !k.startsWith('_'))
for (const k of declaredKeys) {
  if (!CONTRAST_PAIRS[k]) {
    problems.push(`色源 contrast 里有本脚本不认识的键「${k}」：CONTRAST_PAIRS 要同步补上，否则这条声明没人复算`)
    continue
  }
  const [fgRef, bgRef] = CONTRAST_PAIRS[k]
  const got = contrast(roleValue(fgRef), roleValue(bgRef))
  if (got === null) { problems.push(`${k}：${fgRef} / ${bgRef} 解析不出不透明色，算不了对比度`); continue }
  const want = palette.contrast[k]
  if (Math.abs(got - want) > 0.05) problems.push(`${k}：色源声明 ${want}，实算 ${round2(got)}（差 ${round2(Math.abs(got - want))} > 0.05）`)
  // 正文与强调项 4.5，其余 3.0
  const floor = /text|accent|gold|danger/.test(k) ? 4.5 : 3.0
  if (got < floor) problems.push(`${k}：实算 ${round2(got)} 低于闸门 ${floor}`)
  else ok(`${k.padEnd(30)} 声明 ${String(want).padEnd(6)} 实算 ${round2(got)} ≥ ${floor} ✓`)
}
for (const k of Object.keys(CONTRAST_PAIRS)) {
  if (!declaredKeys.includes(k)) notes.push(`CONTRAST_PAIRS 里的「${k}」在色源 contrast 块里没有声明值，只跑了闸门`)
}

const tokenColor = (ref) => {
  if (ref.startsWith('#') || ref.startsWith('rgb')) return ref
  const [g, k] = ref.split('.')
  return tokens[g]?.[k]
}
for (const [fg, bg, floor, why] of TOKEN_GATES) {
  const got = contrast(tokenColor(fg), tokenColor(bg))
  if (got === null) { problems.push(`本仓闸门 ${fg} / ${bg}：算不出对比度`); continue }
  if (got < floor) problems.push(`本仓闸门不过：${why}  ${fg} on ${bg} = ${round2(got)} < ${floor}`)
  else ok(`${why.padEnd(16)} ${fg} on ${bg} = ${round2(got)} ≥ ${floor} ✓`)
}
notes.push('L.fgFaint（最淡一档文字）对浅底约 2.5:1，是装饰层不是信息层，沿旧体系不设闸门')

// ---------- 结果 ----------
console.log('')
for (const n of notes) console.log('ℹ ' + n)
if (problems.length) {
  console.error(`\n✗ 配色闸门 ${problems.length} 处不过：\n`)
  for (const p of problems) console.error('  - ' + p)
  process.exit(1)
}
console.log(`\n✓ 配色闸门全过（色源 ${palette.name}，${pairs} 个颜色令牌两端对齐，${declaredKeys.length} 条声明对比度复算一致，${TOKEN_GATES.length} 条本仓闸门达标）`)
