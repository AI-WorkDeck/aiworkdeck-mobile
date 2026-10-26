#!/usr/bin/env node
// contract/tools/gen.mjs — 写出四端生成物并刷新 contract.json 的 sha 清单。用法：node contract/tools/gen.mjs [--root DIR]
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { loadContract, outputs, manifestFor, syncStringsJson } from './lib.mjs'

const args = process.argv.slice(2)
const i = args.indexOf('--root')
const root = resolve(i >= 0 ? args[i + 1] : join(dirname(fileURLToPath(import.meta.url)), '..', '..'))
syncStringsJson(root)
const c = loadContract(root)
for (const [rel, content] of outputs(c)) {
  const abs = join(root, rel)
  mkdirSync(dirname(abs), { recursive: true })
  writeFileSync(abs, content)
  console.log('wrote', rel)
}
writeFileSync(join(root, 'contract', 'contract.json'), JSON.stringify(manifestFor(root, c.manifest.version), null, 2) + '\n')
console.log('refreshed contract/contract.json')
