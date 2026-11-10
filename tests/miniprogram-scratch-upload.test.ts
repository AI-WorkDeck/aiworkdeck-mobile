import { test } from 'node:test'
import assert from 'node:assert/strict'

// 临时项目 is the cloud scratch project: without persistent cloud storage the server refuses it,
// so captures headed there must return to the phone instead of failing.
let storage: Record<string, any> = {}
let uploads: string[] = []
let usage: any = { usedBytes: 0, quotaBytes: 200, persistentUsedBytes: 9000, persistentQuotaBytes: 0 }
;(globalThis as any).wx = {
  getStorageSync: (key: string) => structuredClone(storage[key]),
  setStorageSync: (key: string, value: any) => { storage[key] = structuredClone(value) },
  removeStorageSync: (key: string) => { delete storage[key] },
  getFileSystemManager: () => ({ saveFile: (o: any) => o.success({ savedFilePath: '/saved/' + o.tempFilePath }), removeSavedFile() {} }),
  showModal() {}, showToast() {}, reLaunch() {}, navigateTo() {},
  uploadFile: (o: any) => { uploads.push(o.formData?.projectKey ?? ''); o.success({ statusCode: 200, data: JSON.stringify({ code: 0 }) }); return {} },
  request: (o: any) => o.url.endsWith('/auth/me') ? o.success({ statusCode: 200, data: { code: 0, data: { id: 71 } } })
    : o.url.endsWith('/media/usage') ? o.success({ statusCode: 200, data: usage })
    : o.url.endsWith('/billing/cloud-state') ? o.success({ statusCode: 404, data: {} })
    : o.success({ statusCode: 200, data: {} }),
}
const { enqueueCapture, listItems, canAssign, retry } = await import('../miniprogram/utils/queue.ts')
const { usageAllowsPersistentWrite } = await import('../miniprogram/utils/api.ts')
const scratch = { deviceId: 'cloud', key: '41', name: '临时项目', deviceName: null, isDefault: true, projectType: 'SCRATCH' }
const desktop = { deviceId: 'mac', key: '7', name: '包晴天', deviceName: 'Mac' }
const settle = () => new Promise(r => setTimeout(r, 20))

test('scratch capture without cloud storage becomes an unassigned local item; desktop still uploads', async () => {
  storage = { 'awd.session': 'synthetic-session' }; uploads = []
  enqueueCapture('a.jpg', 'image', scratch as any)
  enqueueCapture('b.jpg', 'image', desktop as any)
  for (let i = 0; i < 10; i++) await settle()
  const items = listItems()
  const local = items.find(it => it.filePath.endsWith('a.jpg'))!
  assert.equal(local.deviceId, ''); assert.equal(local.projectKey, '')
  assert.equal(local.state, 'waiting'); assert.equal(local.errorMessage, undefined)
  assert.ok(canAssign(local), 'can be filed later from the gallery')
  assert.equal(items.find(it => it.filePath.endsWith('b.jpg'))!.state, 'uploaded')
})

test('a stuck failed scratch upload is released on retry', async () => {
  storage = { 'awd.session': 'synthetic-session', 'awd.queue': [{ clientMediaId: 'f', fileName: 'x.jpg', mediaType: 'image', filePath: '/f.jpg', saved: true,
    deviceId: 'cloud', projectKey: '41', projectName: '临时项目', projectScratch: true, capturedAt: new Date().toISOString(),
    state: 'failed', errorMessage: 'storage limit', attempts: 4, createdAt: 1 }] }
  uploads = []
  retry('f')
  for (let i = 0; i < 10; i++) await settle()
  const [item] = listItems()
  assert.equal(item.deviceId, ''); assert.equal(item.state, 'waiting'); assert.equal(item.errorMessage, undefined)
  assert.deepEqual(uploads, [])
})

test('writable needs a known free quota', () => {
  assert.equal(usageAllowsPersistentWrite({ usedBytes: 0, quotaBytes: 1, persistentUsedBytes: 9000, persistentQuotaBytes: 0 }), false)
  assert.equal(usageAllowsPersistentWrite({ usedBytes: 0, quotaBytes: 1 }), false)
  assert.equal(usageAllowsPersistentWrite({ usedBytes: 0, quotaBytes: 1, persistentQuotaBytes: 3000, persistentQuotaAvailable: false }), false)
  assert.equal(usageAllowsPersistentWrite({ usedBytes: 0, quotaBytes: 1, persistentUsedBytes: 9000, persistentQuotaBytes: 3221225472 }), true)
})

test('subscribers keep uploading to 临时项目', async () => {
  storage = { 'awd.session': 'synthetic-session' }; uploads = []
  usage = { usedBytes: 0, quotaBytes: 200, persistentUsedBytes: 9000, persistentQuotaBytes: 3221225472 }
  enqueueCapture('c.jpg', 'image', scratch as any)
  for (let i = 0; i < 10; i++) await settle()
  assert.equal(listItems()[0].state, 'uploaded')
  assert.equal(listItems()[0].deviceId, 'cloud')
})
