#!/usr/bin/env node
// contract/tools/check.mjs — 契约校验。① 清单 sha ② 引用闭合 ③ 数据文件 schema ④ 夹具 schema + 与迁移表一致 ⑤ 生成物未过期 ⑥ API 副本未漂 ⑦ 无内联文案
// 另有一条只提示不报错的：夹具里还没有任何一端消费的段（runChecks 的 notes，CLI 打 ℹ）
// 用法：node contract/tools/check.mjs [--root DIR] [--quick]   （--quick 跳过 ⑦）
import { readFileSync, existsSync, readdirSync } from 'node:fs'
import { join, dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import Ajv2020 from 'ajv/dist/2020.js'
import { loadContract, manifestFor, DATA_FILES, outputs, sha256 } from './lib.mjs'

const FIXTURES = ['tally', 'transitions', 'status-merge', 'restore', 'delete-warning', 'billing']

function evalGuard(guard, attempts, state, problems) {
  if (!guard) return true
  if (guard === 'attempts <= maxAutoRetries') return attempts <= state.maxAutoRetries
  problems?.push(`迁移表里有未知 guard「${guard}」：校验器认不出，四端也实现不了`)
  return false
}

/** 参考实现：只在校验器里用，四端各自手写同语义的函数并用夹具对拍 */
export function referenceNext(state, from, event, attempts, problems) {
  const rules = state.transitions.filter((t) => t.from === from && t.event === event)
  if (rules.length === 0) return null
  for (const r of rules) if (evalGuard(r.guard, attempts, state, problems)) return r.to
  return from
}

function checkManifest(c, problems) {
  const expected = manifestFor(c.root, c.manifest.version)
  for (const f of DATA_FILES) {
    if (c.manifest.files[f] !== expected.files[f]) problems.push(`contract.json 里 ${f} 的 sha 过期：改了数据没跑 gen`)
  }
}

/** ② 引用闭合：状态机里的每个名字都必须能在状态表 / 文案词典 / 令牌表里落地 */
function checkReferences(c, problems) {
  const s = c.state
  const states = new Set(s.states)
  const key = (k, where) => {
    if (!c.strings[k]) problems.push(`${where} 指向的文案键 ${k} 不在 strings.json 里`)
  }

  for (const [alias, to] of Object.entries(s.aliases ?? {})) {
    if (!states.has(to)) problems.push(`别名 ${alias} 指向未知状态 ${to}`)
  }

  const phaseOf = new Map()
  for (const [phase, p] of Object.entries(s.phases ?? {})) {
    for (const st of p.states ?? []) {
      if (!states.has(st)) problems.push(`桶 ${phase} 含未知状态 ${st}`)
      if (phaseOf.has(st)) problems.push(`状态 ${st} 同时属于桶 ${phaseOf.get(st)} 与 ${phase}：每个状态只能属一个桶`)
      else phaseOf.set(st, phase)
    }
    key(p.label, `桶 ${phase} 的 label`)
    const [grp, name] = String(p.dot ?? '').split('.')
    if (!c.tokens[grp]?.[name]) problems.push(`桶 ${phase} 的点色令牌 ${p.dot} 不在 tokens.json 里`)
  }
  for (const st of s.states) if (!phaseOf.has(st)) problems.push(`状态 ${st} 不属于任何桶`)

  const [fgrp, fname] = String(s.failedDot ?? '').split('.')
  if (!c.tokens[fgrp]?.[fname]) problems.push(`failedDot 令牌 ${s.failedDot} 不在 tokens.json 里`)

  for (const st of s.states) {
    key(s.stateText?.[st], `stateText[${st}]`)
    key(s.stateDetail?.[st], `stateDetail[${st}]`)
    key(s.whereItIs?.[st], `whereItIs[${st}]`)
  }
  for (const [level, k] of Object.entries(s.deleteWarning?.keys ?? {})) key(k, `deleteWarning.keys.${level}`)
  for (const [cap, v] of Object.entries(c.caps.capabilities ?? {})) {
    if (v.degradedNotice) key(v.degradedNotice, `capabilities.${cap}.degradedNotice`)
  }

  if (s.maxAutoRetries !== (s.retryDelaysMs ?? []).length) {
    problems.push(`maxAutoRetries=${s.maxAutoRetries} 与 retryDelaysMs 的长度 ${(s.retryDelaysMs ?? []).length} 对不上`)
  }

  const events = new Set(s.events ?? [])
  for (const t of s.transitions ?? []) {
    if (!states.has(t.from)) problems.push(`迁移 ${t.from}+${t.event} 的起点是未知状态 ${t.from}`)
    if (!states.has(t.to)) problems.push(`迁移 ${t.from}+${t.event} 的终点是未知状态 ${t.to}`)
    if (!events.has(t.event)) problems.push(`迁移 ${t.from}+${t.event} 的事件不在 events 里`)
  }
}

/**
 * ③ 数据文件的形状校验。以前 capabilities.json 一个字都没人校验：把 "android" 打成 "andriod"，
 * 生成的安卓能力开关会变成字符串 "undefined"，而 check.mjs 全绿退出码 0（dev-board#425 复审实测）。
 */
function checkDataSchemas(c, problems) {
  const ajv = new Ajv2020({ allErrors: true })
  for (const [file, data] of [['capabilities', c.caps], ['products', c.products]]) {
    const schema = JSON.parse(readFileSync(join(c.root, 'contract', 'schema', `${file}.schema.json`), 'utf8'))
    const validate = ajv.compile(schema)
    if (!validate(data)) {
      for (const e of validate.errors) problems.push(`${file}.json 不合 schema：${e.instancePath || '/'} ${e.message}`)
    }
  }
}

const CURRENCY_SYMBOL = { CNY: '¥', USD: '$' }

/**
 * 参考实现：金额展示口径（唯一来源是 contract/schema/billing.schema.json 的说明段）——
 * 符号按 currency 取 + 固定两位小数、**无千分位**、**不跟设备 locale**。
 * 只在校验器里用；三端各自手写同语义的函数，拿夹具的 display 对拍（dev-board#425 二轮复审 N7）。
 */
export function referenceMoneyDisplay(cents, currency) {
  const symbol = CURRENCY_SYMBOL[currency]
  if (!symbol || !Number.isInteger(cents)) return null
  const abs = Math.abs(cents)
  return `${symbol}${cents < 0 ? '-' : ''}${Math.trunc(abs / 100)}.${String(abs % 100).padStart(2, '0')}`
}

/**
 * billing 夹具的额外约束（schema 表达不了的三条）：
 * ① 八个 kind 一个不缺——少一个就意味着有一类服务端失败没有任何一端对过；
 * ② expect 就是 json 的解码结果，缺席的键解成 null，夹具不能自说自话；
 * ③ balance 的 display 由参考实现复算，夹具同样不能自说自话。
 */
function checkBillingFixture(c, problems) {
  const schema = JSON.parse(readFileSync(join(c.root, 'contract', 'schema', 'billing.schema.json'), 'utf8'))
  const data = JSON.parse(readFileSync(join(c.root, 'contract', 'fixtures', 'billing.json'), 'utf8'))
  const cases = Array.isArray(data.envelope) ? data.envelope : []
  const seen = new Set(cases.map((k) => k.json?.kind).filter(Boolean))
  for (const kind of schema.$defs.kind.enum) {
    if (!seen.has(kind)) problems.push(`fixtures/billing.json 的 envelope 没有 kind=${kind} 的用例：四端就没有这一类失败可对`)
  }
  for (const k of cases) {
    for (const f of ['code', 'message', 'kind', 'outTradeNo']) {
      const want = k.json?.[f] ?? null
      if ((k.expect?.[f] ?? null) !== want) {
        problems.push(`fixtures/billing.json：「${k.name}」的 expect.${f} 应是 ${JSON.stringify(want)}（json 里没这个键就是 null）`)
      }
    }
  }
  for (const k of Array.isArray(data.balance) ? data.balance : []) {
    const want = referenceMoneyDisplay(k.json?.balanceCents, k.json?.currency)
    if (want === null) {
      problems.push(`fixtures/billing.json：「${k.name}」的 currency=${JSON.stringify(k.json?.currency)} 还没有约定符号——先在 billing.schema.json 的展示口径里补这一种币种，再改各端`)
    } else if (k.display !== want) {
      problems.push(`fixtures/billing.json：「${k.name}」的 display 应是 ${JSON.stringify(want)}（符号按 currency 取 + 两位小数、无千分位、不跟设备 locale），夹具写的是 ${JSON.stringify(k.display)}`)
    }
  }
}

/**
 * 夹具里**还没有任何一端适配测试消费**的段。不报错（本期没有消费方是有意的），但要留一条明确记号：
 * 没人消费的段等于没有约束力——第二期做充值界面时把 present=redirect 的 codeUrl 解成空串，
 * 契约层照样拦不住（dev-board#425 二轮复审 N3）。补了适配测试就把端名填进来。
 */
const FIXTURE_CONSUMERS = {
  billing: {
    balance: ['ios', 'miniprogram', 'android'], envelope: ['ios', 'miniprogram', 'android'],
    // 小程序虚拟支付（dev-board#427）起，recharge / status 两段由 tests/contract.test.ts 走
    // 生产解码路径消费（readEnvelope + decodeRechargeOrder / decodeRechargeStatus）；
    // iOS 内购（dev-board#426）起同样由 ios/Tests/ContractFixturesTests 驱动
    // API.decodeRechargeOrder / API.decodeRechargeStatus（含 present=native 与 appAccountToken）
    recharge: ['miniprogram', 'ios'], status: ['miniprogram', 'ios'],
  },
}
function checkFixtureConsumers(c, notes) {
  for (const [file, sections] of Object.entries(FIXTURE_CONSUMERS)) {
    const data = JSON.parse(readFileSync(join(c.root, 'contract', 'fixtures', `${file}.json`), 'utf8'))
    for (const section of Object.keys(data)) {
      if ((sections[section] ?? []).length === 0) {
        notes.push(`fixtures/${file}.json 的「${section}」段还没有任何一端的夹具适配测试消费——第二期做充值界面时补上（docs/specs/2026-09-04-mobile-recharge-design.md §8 第二期清单），补完把端名填进 check.mjs 的 FIXTURE_CONSUMERS`)
      }
    }
  }
}

function checkFixtures(c, problems) {
  const ajv = new Ajv2020({ allErrors: true })
  for (const name of FIXTURES) {
    const schema = JSON.parse(readFileSync(join(c.root, 'contract', 'schema', `${name}.schema.json`), 'utf8'))
    const data = JSON.parse(readFileSync(join(c.root, 'contract', 'fixtures', `${name}.json`), 'utf8'))
    const validate = ajv.compile(schema)
    if (!validate(data)) {
      for (const e of validate.errors) problems.push(`fixtures/${name}.json 不合 schema：${e.instancePath} ${e.message}`)
    }
  }
  // 迁移夹具的期望必须由迁移表推出，夹具不能自说自话
  const tr = JSON.parse(readFileSync(join(c.root, 'contract', 'fixtures', 'transitions.json'), 'utf8'))
  if (!Array.isArray(tr.cases)) problems.push('fixtures/transitions.json 没有 cases 数组')
  else for (const k of tr.cases) {
    const got = referenceNext(c.state, k.from, k.event, k.attempts, problems)
    if (got !== k.to) problems.push(`fixtures/transitions.json：${k.from}+${k.event}(attempts=${k.attempts}) 期望 ${k.to}，迁移表推出 ${got}`)
  }
  const rs = JSON.parse(readFileSync(join(c.root, 'contract', 'fixtures', 'restore.json'), 'utf8'))
  if (!Array.isArray(rs.cases)) problems.push('fixtures/restore.json 没有 cases 数组')
  else for (const k of rs.cases) {
    const got = referenceNext(c.state, k.state, 'app_launch', k.attempts, problems) ?? k.state
    if (got !== k.expect) problems.push(`fixtures/restore.json：${k.state}(attempts=${k.attempts}) 期望 ${k.expect}，迁移表推出 ${got}`)
  }
}

function checkGenerated(c, problems) {
  for (const [rel, content] of outputs(c)) {
    const abs = join(c.root, rel)
    if (!existsSync(abs)) { problems.push(`生成物缺失：${rel}（跑 node contract/tools/gen.mjs）`); continue }
    if (readFileSync(abs, 'utf8') !== content) problems.push(`生成物过期或被手改：${rel}（跑 node contract/tools/gen.mjs）`)
  }
}

function checkApiPin(c, problems) {
  const y = join(c.root, 'contract', 'api', 'mobile-v1.yaml')
  const p = join(c.root, 'contract', 'api', 'PINNED.json')
  if (!existsSync(y) || !existsSync(p)) { console.warn('⚠ contract/api 尚无副本，跳过 ④（服务端计划完成后跑 pull-api.mjs）'); return }
  const pinned = JSON.parse(readFileSync(p, 'utf8'))
  if (sha256(readFileSync(y, 'utf8')) !== pinned.sha256) problems.push('contract/api/mobile-v1.yaml 的 sha 与 PINNED.json 不一致：副本被手改，重跑 pull-api.mjs')
}

function walk(dir, exts, skip, out = []) {
  if (!existsSync(dir)) return out
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name)
    if (skip.some((s) => p.includes(s))) continue
    if (e.isDirectory()) walk(p, exts, skip, out)
    else if (exts.some((x) => e.name.endsWith(x))) out.push(p)
  }
  return out
}

const CJK = /\p{Script=Han}/u
/** 带占位的文案拆出的片段短于这个长度就不查了：太短，误报比漏报还烦 */
const MIN_SEGMENT = 3

/** 允许保留在源码里的少量非词典中文（语言选择器原生标签、字体名、调试种子与内部不变式日志） */
const ALLOWED_CJK_TOKENS = ['简体中文', '中文', 'PingFang SC', "name: '走查项目'"]
const ALLOWED_CJK_FILE_SUFFIXES = [
  'ios/Sources/App/Screenshots.swift',
  'android/app/src/main/kotlin/com/aiworkdeck/mobile/ScreenshotMode.kt',
  'harmony/entry/src/main/ets/ScreenshotMode.ets',
]
const ALLOWED_CJK_LINE_PATTERNS = [
  /\b(?:albumLogger|logger)\.(?:warning|info)\s*\(/,
  /\b(?:preconditionFailure|DecodingError\.dataCorrupted|IOException)\s*\(/,
  /\berror\s*\(\s*"(?:未知|契约)/,
]

function checkStrings(c, problems) {
  const placeholders = (s) => [...String(s ?? '').matchAll(/\{(\w+)\}/g)].map((m) => m[1]).sort().join(',')
  for (const [k, v] of Object.entries(c.strings ?? {})) {
    const zh = v?.['zh-Hans']
    const en = v?.en
    if (typeof zh !== 'string' || zh.trim().length === 0) problems.push(`strings.json 的 ${k} 缺少 zh-Hans 文案`)
    if (typeof en !== 'string' || en.trim().length === 0) problems.push(`strings.json 的 ${k} 缺少 en 文案`)
    if (typeof zh === 'string' && typeof en === 'string' && placeholders(zh) !== placeholders(en)) {
      problems.push(`strings.json 的 ${k} 占位符不一致：zh-Hans={${placeholders(zh)}} vs en={${placeholders(en)}}`)
    }
  }
}

/** 注释里的中文不算内联文案（说明为什么这么写常常要引用原文） */
function stripComments(text) {
  return text
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .replace(/<!--[\s\S]*?-->/g, (m) => m.replace(/[^\n]/g, ' '))
    .split('\n')
    .map((l) => l.replace(/\/\/.*$/, ''))
    .join('\n')
}

function isAllowedCjkLine(rel, line) {
  if (ALLOWED_CJK_FILE_SUFFIXES.some((s) => rel.endsWith(s))) return true
  if (ALLOWED_CJK_LINE_PATTERNS.some((re) => re.test(line))) return true
  let rest = line
  for (const tok of ALLOWED_CJK_TOKENS) rest = rest.split(tok).join('')
  return !CJK.test(rest)
}

function checkInline(c, problems) {
  const plain = []      // 无占位：整值查三种引号形态
  const segments = []   // 有占位：按 {x} 切开，中文片段逐行找原样出现（跨插值也能抓到）
  for (const v of Object.values(c.strings)) {
    const zh = v['zh-Hans']
    if (!zh.includes('{')) { plain.push(zh); continue }
    for (const seg of zh.split(/\{\w+\}/)) {
      if (seg.length >= MIN_SEGMENT && CJK.test(seg)) segments.push({ seg, zh })
    }
  }
  const files = [
    ...walk(join(c.root, 'ios', 'Sources'), ['.swift'], ['/Contract/']),
    ...walk(join(c.root, 'ios', 'Workdeck'), ['.swift'], ['L10n.generated.swift']),
    ...walk(join(c.root, 'ios', 'Shared'), ['.swift'], []),
    ...walk(join(c.root, 'ios', 'LiveActivity'), ['.swift'], []),
    ...walk(join(c.root, 'miniprogram', 'pages'), ['.ts', '.wxml'], []),
    ...walk(join(c.root, 'miniprogram', 'components'), ['.ts', '.wxml'], []),
    ...walk(join(c.root, 'miniprogram', 'utils'), ['.ts'], ['/utils/contract/', 'strings.ts']),
    ...walk(join(c.root, 'android', 'app', 'src', 'main'), ['.kt'], []),
    ...walk(join(c.root, 'harmony', 'entry', 'src', 'main'), ['.ets'], []),
  ]
  const appTs = join(c.root, 'miniprogram', 'app.ts')
  if (existsSync(appTs)) files.push(appTs)
  for (const f of files) {
    const rel = f.slice(c.root.length + 1)
    const text = stripComments(readFileSync(f, 'utf8'))
    for (const v of plain) {
      for (const form of [`"${v}"`, `'${v}'`, `>${v}<`]) {
        if (text.includes(form)) problems.push(`内联文案 ${form} 于 ${rel}：改用 strings.json 的键`)
      }
    }
    const seen = new Set()
    const lines = text.split('\n')
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i]
      for (const { seg, zh } of segments) {
        if (!line.includes(seg) || seen.has(seg)) continue
        seen.add(seg)
        problems.push(`内联文案片段「${seg}」（出自「${zh}」）于 ${rel}：改用 strings.json 的键`)
      }
      if (CJK.test(line) && !isAllowedCjkLine(rel, line)) {
        problems.push(`内联硬编码中文于 ${rel}:${i + 1}（${line.trim()}）：改用 strings.json 的键`)
      }
    }
  }
}

/** 签名材料不进仓（spec H11）：DevEco 自动签名会往 build-profile.json5 里写口令 */
function checkHarmonySigning(c, problems) {
  const p = join(c.root, 'harmony', 'build-profile.json5')
  if (existsSync(p) && /storePassword|keyPassword/.test(readFileSync(p, 'utf8')))
    problems.push('harmony/build-profile.json5 含签名口令：signingConfigs 不进仓，改回 []')
}

export function runChecks(root, { quick = false } = {}) {
  const problems = []
  const notes = []
  let c
  try { c = loadContract(root) } catch (e) { return { ok: false, problems: [`contract/ 读不进来：${e.message}`], notes } }
  checkManifest(c, problems)
  checkStrings(c, problems)
  checkReferences(c, problems)
  checkDataSchemas(c, problems)
  checkFixtures(c, problems)
  checkBillingFixture(c, problems)
  checkFixtureConsumers(c, notes)
  checkGenerated(c, problems)
  checkHarmonySigning(c, problems)
  checkApiPin(c, problems)
  if (!quick) checkInline(c, problems)
  return { ok: problems.length === 0, problems, notes }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2)
  const i = args.indexOf('--root')
  const root = resolve(i >= 0 ? args[i + 1] : join(dirname(fileURLToPath(import.meta.url)), '..', '..'))
  const r = runChecks(root, { quick: args.includes('--quick') })
  for (const n of r.notes ?? []) console.log('ℹ', n)
  if (!r.ok) { for (const p of r.problems) console.error('✗', p); process.exit(1) }
  console.log('契约校验通过')
}
