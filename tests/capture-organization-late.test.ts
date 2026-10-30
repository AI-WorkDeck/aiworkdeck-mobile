// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import ts from 'typescript'
import { processQueue, listItems } from '../miniprogram/utils/queue.ts'
import { setSession } from '../miniprogram/utils/api.ts'

const previous = (globalThis as any).wx
afterEach(() => { (globalThis as any).wx = previous })
const result = { state: 'ready', originalName: 'original.jpg', archiveName: 'archive.jpg', fileName: 'archive.jpg', tags: ['Synthetic'] }

test('delayed mini-program upload cannot recreate results after logout or same-user re-login', async () => {
  for (const change of ['logout', 'relogin', 'unchanged']) {
    const id = 'synthetic-' + change
    const storage = new Map<string, any>([
      ['awd.session', 'session-a'], ['awd.user', { id: 71 }],
      ['awd.queue', [{ clientMediaId: id, filePath: '/synthetic/original.jpg', fileName: 'original.jpg', saved: true,
        deviceId: 'desktop-a', projectKey: '1', projectName: 'Synthetic', mediaType: 'image', capturedAt: '2026-10-30T10:00:00Z', createdAt: 1, state: 'waiting' }]],
    ])
    let pending: any
    ;(globalThis as any).wx = {
      getStorageSync: (key: string) => structuredClone(storage.get(key)),
      setStorageSync: (key: string, value: unknown) => storage.set(key, structuredClone(value)),
      removeStorageSync: (key: string) => storage.delete(key),
      getFileSystemManager: () => ({ unlink() {} }),
      uploadFile: (options: any) => { pending = options; return {} },
    }
    processQueue()
    assert.ok(pending, 'actual upload must already be in flight')
    if (change === 'logout') setSession(null)
    if (change === 'relogin') setSession('session-b')
    pending.success({ statusCode: 200, data: JSON.stringify({ code: 0, organization: result }) })
    await new Promise(resolve => setImmediate(resolve))
    const item = listItems()[0]
    assert.equal(item.filePath, '/synthetic/original.jpg')
    assert.equal(item.state, 'uploaded')
    if (change === 'unchanged') assert.equal(item.organization?.archiveName, 'archive.jpg')
    else assert.equal(item.organization, undefined)
  }
})

function harmonyPrefs(flush: () => Promise<void>) {
  const values = new Map<string, any>()
  const store = {
    getSync: (key: string, fallback: unknown) => values.get(key) ?? fallback,
    putSync: (key: string, value: unknown) => values.set(key, value),
    deleteSync: (key: string) => values.delete(key),
    put: async (key: string, value: unknown) => { values.set(key, value) },
    delete: async (key: string) => { values.delete(key) },
    getAll: async () => Object.fromEntries(values), flush,
  }
  const source = readFileSync(new URL('../harmony/entry/src/main/ets/services/Prefs.ets', import.meta.url), 'utf8')
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
  const exports: any = {}
  const require = (name: string) => {
    if (name === '@kit.ArkData') return { preferences: { getPreferences: async () => store, getPreferencesSync: () => store } }
    if (name === '@kit.ArkTS') return { JSON, util: {} }
    if (name === './ApiTypes') return { decodeCaptureOrganization: (value: any) => value, asRecord: (value: any) => value }
    return {}
  }
  new Function('require', 'exports', output)(require, exports)
  return { prefs: new exports.Prefs({}), values }
}

test('Harmony rejects a late result before writing after session or site changed', async () => {
  const { prefs, values } = harmonyPrefs(async () => {})
  await prefs.saveOrganization('old-scope', 'capture', result, async () => false)
  assert.equal(values.size, 0)
  await prefs.saveOrganization('old-scope', 'capture', result, async () => true)
  assert.equal(values.size, 1, 'control case must actually persist')
})

test('Harmony clearing during pending disk flush leaves no resurrected organization result', async () => {
  let current = true, release: (() => void) | undefined, flushing: (() => void) | undefined
  const reachedFlush = new Promise<void>(resolve => { flushing = resolve })
  let calls = 0
  const { prefs, values } = harmonyPrefs(() => {
    if (++calls !== 1) return Promise.resolve()
    flushing!()
    return new Promise<void>(resolve => { release = resolve })
  })
  const saving = prefs.saveOrganization('old-scope', 'capture', result, async () => current)
  await reachedFlush
  assert.equal(values.size, 1, 'write must already be pending')
  current = false
  await prefs.clearOrganization('old-scope')
  release!()
  await saving
  assert.equal(values.size, 0)
})
