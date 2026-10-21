import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import ts from 'typescript'
// @ts-ignore ArkTS pure modules.
import * as models from '../../harmony/entry/src/main/ets/model/ProjectFiles.ets'
// @ts-ignore ArkTS pure modules.
import * as capture from '../../harmony/entry/src/main/ets/model/Capture.ets'
// @ts-ignore ArkTS pure modules.
import * as envelope from '../../harmony/entry/src/main/ets/model/Envelope.ets'
// @ts-ignore ArkTS pure modules.
import * as api from '../../harmony/entry/src/main/ets/services/ApiTypes.ets'

const project = { projectUid: 'p-1', name: 'Synthetic', deviceId: 'desktop', key: 'key',
  locations: [{ kind: 'desktop', deviceId: 'desktop', key: 'key', online: true }] }
const file = { id: 'f-1', uid: 'f-uid', name: 'a.pdf', path: 'folder/a.pdf', size: 3, deviceId: 'desktop', projectKey: 'key', source: 'desktop' }

function fixture() {
  const files = new Map<string, Buffer>()
  const descriptors = new Map<number, string>()
  let sequence = 0
  let currentSession = 'synthetic-session'
  const calls: Array<{path: string; body: any}> = []
  const previews: any[] = []
  let supported = true
  let responseType = 'application/octet-stream'
  let downloadBytes = Buffer.from('abc')
  let streamOptions: any
  let catalog: any[] = [project]
  let request = async (path: string, _body: any): Promise<any> => {
    if (path.endsWith('/preview/pull')) return { id: 7 }
    if (path.endsWith('/transfer/7')) return { transfer: { id: 7, kind: 'PULL', status: 'STAGED', fileSize: 3 } }
    return { code: 0 }
  }
  const fs = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync: (p: string) => files.has(p) || p.endsWith('/ProjectPreviews'),
    mkdirSync: () => {},
    listFileSync: (p: string) => [...files.keys()].filter(k => k.startsWith(p + '/')).map(k => k.slice(p.length + 1)),
    openSync: (p: string) => { if (!files.has(p)) files.set(p, Buffer.alloc(0)); const fd = ++sequence; descriptors.set(fd, p); return { fd } },
    closeSync: () => {},
    writeSync: (fd: number, data: string | ArrayBuffer) => {
      const p = descriptors.get(fd)!; const next = typeof data === 'string' ? Buffer.from(data) : Buffer.from(data)
      files.set(p, Buffer.concat([files.get(p)!, next])); return next.length
    },
    renameSync: (a: string, b: string) => { files.set(b, files.get(a)!); files.delete(a) },
    unlinkSync: (p: string) => { files.delete(p) },
    readTextSync: (p: string) => files.get(p)!.toString(),
    statSync: (p: string) => ({ size: files.get(p)!.length }),
  }
  const backend = {
    myProjects: async () => catalog,
    backupConsent: async () => ({ enabled: true, decided: true, subscriptionActive: true }),
    fileRequest: async (path: string, body: any) => { calls.push({ path, body: structuredClone(body) }); return request(path, body) },
  }
  const locator = { ctx: { filesDir: '/private' }, session: { current: async () => currentSession }, baseUrl: () => 'https://synthetic.invalid', backend }
  const modules: Record<string, any> = {
    '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, createHttp: () => {
      const events: Record<string, Function> = {}
      return { on: (event: string, cb: Function) => { events[event] = cb }, destroy: () => {},
        requestInStream: async (_url: string, options: any) => {
          streamOptions = options
          events.headersReceive({ 'content-type': responseType })
          setTimeout(() => {
            events.dataReceive(downloadBytes.buffer.slice(downloadBytes.byteOffset, downloadBytes.byteOffset + downloadBytes.length))
            events.dataEnd()
          }, 1)
          return 200
        } }
    } } },
    '@kit.CoreFileKit': { fileIo: fs, fileUri: { getUriFromPath: (p: string) => p } },
    '@kit.PreviewKit': { filePreview: { canPreview: async () => supported, openPreview: async (_ctx: any, info: any) => previews.push(info) } },
    '@kit.ArkTS': { JSON, util: { generateRandomUUID: () => `synthetic-${++sequence}`, TextEncoder: class { encodeInto(s: string) { return new TextEncoder().encode(s) } } } },
    '@kit.CryptoArchitectureKit': { cryptoFramework: { createMd: () => { const hash = createHash('sha256'); return { updateSync: ({data}: any) => hash.update(data), digestSync: () => ({ data: hash.digest() }) } } } },
    '../model/Envelope': envelope, '../model/Capture': capture, '../model/ProjectFiles': models,
    './ApiTypes': api, './ServiceLocator': { ServiceLocator: locator }, '../design/L10n': { tr: (key: string) => key },
  }
  const source = readFileSync(new URL('../../harmony/entry/src/main/ets/services/ProjectFilesService.ets', import.meta.url), 'utf8')
  const output = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
  const exports: any = {}
  new Function('require', 'exports', output)((id: string) => { assert.ok(modules[id], id); return modules[id] }, exports)
  const service = new exports.ProjectFilesService(currentSession)
  return { service, files, calls, previews, backend,
    session: (s: string) => { currentSession = s }, supported: (v: boolean) => { supported = v },
    request: (fn: typeof request) => { request = fn }, catalog: (value: any[]) => { catalog = value },
    bytes: (value: Buffer) => { downloadBytes = value }, type: (value: string) => { responseType = value },
    options: () => streamOptions }
}

test('folder listing preserves explicit empty folders and nested files', () => {
  const rows = [file, { ...file, id: 'empty', uid: undefined, path: 'empty', name: 'empty', isFolder: true, size: 0 }]
  assert.deepEqual(models.folderEntries(rows).map((f: any) => f.name), ['empty', 'folder'])
  assert.equal(models.folderEntries(rows, 'folder')[0].file.id, 'f-1')
  assert.throws(() => models.decodeFileListing({ files: [{ id: 'bad', name: 'bad', size: -1 }] }))
  assert.throws(() => models.decodeBackupConsent({ enabled: true }))
})

test('unsupported, missing viewer and oversized formats are blocked without a request', async () => {
  const f = fixture()
  await assert.rejects(f.service.canOpen({ ...file, name: 'app.exe' }))
  await assert.rejects(f.service.canOpen({ ...file, size: 201 * 1024 * 1024 }))
  f.supported(false)
  await assert.rejects(f.service.canOpen(file), /files.noPreviewApp/)
  assert.equal(f.calls.length, 0)
  assert.equal(f.files.size, 0)
})

test('charged request retry restores the original full body after lost creation response', async () => {
  const f = fixture()
  f.request(async () => { throw new Error('lost response') })
  await assert.rejects(f.service.preview(project, file, true), /lost response/)
  const original = f.calls[0].body
  assert.equal(f.service.hasPending(project, file), true)
  await assert.rejects(f.service.preview(project, { ...file, name: 'renamed.pdf', size: 30 }, true))
  assert.deepEqual(f.calls[1].body, original)
  assert.equal([...f.files.values()].some(b => b.toString().includes('synthetic-session')), false)
})

test('stream completion is awaited, bytes validated, redirects disabled, ACK and completed cache cleaned', async () => {
  const f = fixture()
  await f.service.preview(project, file, true)
  assert.equal(f.previews.length, 1)
  assert.equal(f.options().maxRedirects, 0)
  assert.equal(f.calls.filter(c => c.path.endsWith('/ack')).length, 1)
  assert.equal(f.files.size, 2)
  f.service.close()
  assert.equal(f.files.size, 0)
})

test('short body and JSON error body are never acknowledged or opened', async () => {
  for (const json of [false, true]) {
    const f = fixture()
    if (json) f.type('application/json'); else f.bytes(Buffer.from('x'))
    await assert.rejects(f.service.preview(project, file, true))
    assert.equal(f.previews.length, 0)
    assert.equal(f.calls.some(c => c.path.endsWith('/ack')), false)
    assert.equal([...f.files.keys()].every(k => k.endsWith('.json')), true)
  }
})

test('backup remains free cloud retrieval while desktop is online; legacy sources remain usable', async () => {
  const f = fixture()
  assert.equal(await f.service.useDesktop(project, { ...file, source: 'backup' }), false)
  const legacy = { ...project, projectUid: undefined, locations: undefined }
  f.catalog([legacy])
  assert.equal(await f.service.useDesktop(legacy, file), true)
  const cloud = { ...project, deviceId: 'cloud' }
  f.catalog([cloud])
  assert.equal(await f.service.useDesktop(cloud, { ...file, source: undefined }), false)
})

test('session switch and closed page invalidate before charging or storing late data', async () => {
  const f = fixture()
  f.session('different')
  await assert.rejects(f.service.preview(project, file, true), /files.error.closed/)
  assert.equal(f.files.size, 0)
  assert.equal(f.calls.length, 0)
  const g = fixture()
  g.service.close()
  await assert.rejects(g.service.canOpen(file), /files.error.closed/)
})

test('terminal failed transfer may be retried fresh; uncertain transport failure keeps its key', async () => {
  const f = fixture()
  f.request(async (path) => path.endsWith('/preview/pull') ? { id: 7 } : { transfer: { id: 7, kind: 'PULL', status: 'EXPIRED' } })
  await assert.rejects(f.service.preview(project, file, true))
  assert.equal(f.service.hasPending(project, file), false)
})

test('retry after catalog rename keeps the original downloaded extension and viewer type', async () => {
  const f = fixture()
  f.request(async () => { throw new Error('lost response') })
  await assert.rejects(f.service.preview(project, file, true))
  f.request(async (path) => path.endsWith('/preview/pull') ? { id: 7 } :
    path.endsWith('/transfer/7') ? { transfer: { id: 7, kind: 'PULL', status: 'STAGED', fileSize: 3 } } : { code: 0 })
  await f.service.preview(project, { ...file, name: 'renamed.mp4' }, true)
  assert.match(f.previews[0].uri, /\.pdf$/)
  assert.equal(f.previews[0].mimeType, 'application/pdf')
})
