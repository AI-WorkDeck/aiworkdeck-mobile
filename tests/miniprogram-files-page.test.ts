import { test } from 'node:test'
import assert from 'node:assert/strict'
let definition: any
;(globalThis as any).Page = (page: any) => { definition = page }
await import('../miniprogram/pages/files/files.ts')

const desktop = { kind: 'desktop', deviceId: 'desk', key: '1', online: true }
const catalog = { projectUid: 'uid', name: '项目', locations: [desktop] }
const project = { projectUid: 'uid', name: '项目', locations: [desktop], deviceId: 'desk', key: '1', deviceName: null }
const pdf = { id: 'f', uid: 'file', name: 'a.pdf', path: '文件夹/a.pdf', size: 12 }
function setup(online = true, enabled = false, subscriptionActive = false, listFailed = false) {
  const requests: string[] = []
  ;(globalThis as any).wx = {
    getStorageSync: (key: string) => key === 'awd.session' ? 'session' : undefined,
    setStorageSync() {},
    request(opts: any) {
      requests.push(opts.url)
      const ok = (data: unknown) => opts.success({ statusCode: 200, data })
      if (opts.url.endsWith('/catalog')) return ok([{ ...catalog, locations: [{ ...desktop, online }] }])
      if (opts.url.endsWith('/backup-consent')) return ok({ enabled, subscriptionActive, decided: true })
      if (opts.url.endsWith('/transfer/list')) return listFailed ? opts.fail() : ok({ code: 0, id: 8 })
      if (opts.url.endsWith('/transfer/8')) return ok({ code: 0, transfer: { id: 8, kind: 'LIST', status: 'DONE', files: [pdf] } })
      if (opts.url.endsWith('/catalog/uid/files')) return ok({ files: [{ ...pdf, source: listFailed ? 'desktop' : 'backup', deviceId: 'desk', projectKey: '1' },
        ...(online ? [{ ...pdf, id: 'cloud-file', uid: 'cloud-uid', name: 'only-cloud.pdf', path: '云端/only-cloud.pdf', source: 'cloud' }] : [])], truncated: false })
      if (opts.url.includes('/quote?')) return opts.fail()
      throw Error('Unexpected request ' + opts.url)
    },
  }
  const page = { ...definition, data: structuredClone(definition.data), project, active: true, session: 'session',
    setData(patch: any) { Object.assign(this.data, patch) } }
  return { page, requests, setOnline(value: boolean) { online = value; listFailed = false } }
}

test('online desktop lists actual directories without requiring subscription or backup consent', async () => {
  const { page, requests } = setup()
  await page.loadFiles()
  assert.equal(page.data.error, '')
  assert.equal(page.data.entries[0].folder, true)
  assert.deepEqual(page.data.entries.map((entry: any) => entry.name).sort(), ['云端', '文件夹'].sort())
  assert.equal(requests.some(x => x.endsWith('/backup-consent')), false)
})

test('offline non-consenting account can browse metadata but file tap never transfers bytes', async () => {
  const { page, requests } = setup(false, false, true)
  await page.loadFiles()
  assert.equal(page.data.error, '')
  assert.equal(page.data.entries[0].folder, true)
  assert.equal(requests.some(x => x.endsWith('/files')), true)
  await page.onEntry({ currentTarget: { dataset: { index: 0 } } })
  await page.onEntry({ currentTarget: { dataset: { index: 0 } } })
  assert.ok(page.data.error)
  assert.equal(requests.some(x => x.includes('/transfer/') || x.includes('/preview/')), false)
})

test('offline subscribed consenting account displays backed-up nested files', async () => {
  const { page, requests } = setup(false, true, true)
  await page.loadFiles()
  assert.equal(page.data.error, '')
  assert.equal(page.data.entries[0].folder, true)
  await page.onEntry({ currentTarget: { dataset: { index: 0 } } })
  assert.equal(page.data.entries[0].name, 'a.pdf')
  assert.equal(requests.some(x => x.includes('/transfer/')), false)
})

test('tapping unsupported file never starts quote, consent lookup or transfer', async () => {
  const { page, requests } = setup()
  page.data.entries = [{ folder: false, file: { ...pdf, name: 'danger.exe' } }]
  await page.onEntry({ currentTarget: { dataset: { index: 0 } } })
  assert.ok(page.data.error)
  assert.deepEqual(requests, [])
})

test('failed live LIST retains cached catalog but stale online flag never authorizes a quote or pull', async () => {
  const { page, requests } = setup(true, false, false, true)
  await page.loadFiles()
  assert.equal(page.data.error, '')
  const folder = page.data.entries.findIndex((entry: any) => entry.name === '文件夹')
  await page.onEntry({ currentTarget: { dataset: { index: folder } } })
  await page.onEntry({ currentTarget: { dataset: { index: 0 } } })
  assert.ok(page.data.error)
  assert.equal(requests.some(x => x.includes('/quote') || x.includes('/preview/')), false)
})

test('refreshing an offline detail rechecks desktop availability and reloads the live directory', async () => {
  const { page, requests, setOnline } = setup(false, false, false)
  await page.loadFiles()
  assert.equal(requests.some(x => x.endsWith('/transfer/list')), false)
  setOnline(true)
  await page.loadFiles()
  assert.equal(page.data.error, '')
  assert.equal(requests.some(x => x.endsWith('/transfer/list')), true)
  assert.equal(page.files.find((file: any) => file.id === 'f').source, 'desktop')
})

test('reconnected desktop replaces an old backup route before consent or cloud content calls', async () => {
  const { page, requests, setOnline } = setup(false, false, false)
  await page.loadFiles()
  await page.onEntry({ currentTarget: { dataset: { index: 0 } } })
  setOnline(true)
  // Stop at quote to prove routing: cloud access would ask for consent instead.
  await page.onEntry({ currentTarget: { dataset: { index: 0 } } })
  assert.equal(requests.some(x => x.includes('/quote?')), true)
  assert.equal(requests.some(x => x.endsWith('/backup-consent')), false)
})
