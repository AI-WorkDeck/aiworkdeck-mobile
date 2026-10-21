import { test } from 'node:test'
import assert from 'node:assert/strict'
import { enqueueCapture, assignCapture, listItems, processQueue, recoverOnLaunch, tallyFor, removeItems } from '../miniprogram/utils/queue.ts'
import { t } from '../miniprogram/utils/i18n.ts'

let storage: Record<string, any> = {}
let saves: any[] = []
let uploads: any[] = []
let routes: string[] = []
let back = 0
let notices: any[] = []
let removed: string[] = []
const project = { deviceId: 'synthetic-desktop', key: '7', projectUid: 'synthetic-uid', name: '合成项目', deviceName: null }
;(globalThis as any).wx = {
  getStorageSync: (key: string) => structuredClone(storage[key]),
  setStorageSync: (key: string, value: any) => { storage[key] = structuredClone(value) },
  getFileSystemManager: () => ({ saveFile: (o: any) => saves.push(o), removeSavedFile: (o: any) => removed.push(o.filePath) }),
  showModal: (o: any) => notices.push(o),
  uploadFile: (o: any) => { uploads.push(o); o.success({ statusCode: 200, data: JSON.stringify({ code: 0 }) }); return {} },
  navigateTo: (o: any) => routes.push(o.url), navigateBack: () => { back++ },
  reLaunch: (o: any) => routes.push(o.url), showToast() {},
  request: (o: any) => o.success({ statusCode: 200, data: [{ ...project, locations: [{ kind: 'desktop', deviceId: project.deviceId, key: project.key, online: true }] }] }),
}
let definition: any
;(globalThis as any).Page = (page: any) => { definition = page }
;(globalThis as any).getApp = () => ({ globalData: { metrics: {} } })
;(globalThis as any).getCurrentPages = () => [{}, {}]
await import('../miniprogram/pages/gallery/gallery.ts')
const gallery = definition
await import('../miniprogram/pages/project/project.ts')
const picker = definition
function instance(def: any) {
  return { ...def, data: structuredClone(def.data), selected: new Set(),
    setData(patch: any) { Object.assign(this.data, patch) } }
}
async function reset() {
  await new Promise(resolve => setImmediate(resolve))
  storage = {}; saves = []; uploads = []; routes = []; back = 0; notices = []; removed = []
}
function saved(index = 0) { saves[index].success({ savedFilePath: `/synthetic/saved-${index}` }) }

test('unassigned photo, video and audio stay local across queue recovery and never use a fake server project', async () => {
  await reset()
  for (const type of ['image', 'video', 'audio'] as const) {
    enqueueCapture(`/synthetic/${type}`, type, null)
    saved(saves.length - 1)
  }
  storage['awd.session'] = 'synthetic-session'
  processQueue(); recoverOnLaunch()
  assert.equal(uploads.length, 0)
  assert.equal(listItems(':').length, 3)
  assert.ok(listItems().every(item => item.saved && item.deviceId === '' && item.projectKey === '' && item.state === 'waiting'))
  assert.deepEqual(tallyFor(':'), { uploading: 0, failed: 0, staged: 0, landed: 0 })
})

test('assigning a locally saved capture starts upload once with its unchanged media identity', async () => {
  await reset()
  const original = enqueueCapture('/synthetic/photo', 'image', null)
  saved()
  assert.equal(assignCapture(original.clientMediaId, project), true)
  assert.equal(uploads.length, 1)
  assert.equal(uploads[0].formData.deviceId, project.deviceId)
  assert.equal(uploads[0].formData.projectKey, project.key)
  assert.equal(uploads[0].formData.clientMediaId, original.clientMediaId)
  assert.equal(listItems()[0].capturedAt, original.capturedAt)
  assert.equal(listItems()[0].projectUid, project.projectUid)
  assert.equal(assignCapture(original.clientMediaId, { ...project, deviceId: 'other' }), false)
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(listItems()[0].state, 'uploaded')
  assert.equal(assignCapture(original.clientMediaId, { ...project, key: '8' }), false)
  assert.equal(listItems()[0].deviceId, project.deviceId)
})

test('assignment while local saving is pending cannot race the file preservation callback', async () => {
  await reset()
  const original = enqueueCapture('/synthetic/photo', 'image', null)
  assert.equal(assignCapture(original.clientMediaId, project), true)
  assert.equal(uploads.length, 0)
  saved()
  assert.equal(uploads.length, 1)
  assert.equal(uploads[0].filePath, '/synthetic/saved-0')
})

test('incomplete targets and media with previous transport attempts cannot be reassigned', async () => {
  await reset()
  const item = enqueueCapture('/synthetic/photo', 'image', null)
  saved()
  assert.equal(assignCapture(item.clientMediaId, { ...project, deviceId: '' }), false)
  storage['awd.queue'][0].attempts = 1
  assert.equal(assignCapture(item.clientMediaId, project), false)
  storage['awd.queue'][0].attempts = 0
  storage['awd.queue'][0].deviceId = 'legacy-destination'
  assert.equal(assignCapture(item.clientMediaId, project), false)
  assert.equal(uploads.length, 0)
})

test('unassigned gallery is visible without a selected project; long press uses the real project picker to assign', async () => {
  await reset()
  const item = enqueueCapture('/synthetic/photo', 'image', null)
  saved()
  const library = instance(gallery)
  library.onLoad()
  library.refresh()
  assert.equal(library.data.viewingName, t('library.unknownProject'))
  assert.equal(library.data.viewingUnassigned, true)
  assert.equal(library.data.days[0].items[0].clientMediaId, item.clientMediaId)
  assert.equal(library.data.days[0].items[0].statusText, t('library.unknownProject'))
  library.onAssign({ currentTarget: { dataset: { id: item.clientMediaId } } })
  assert.deepEqual(routes, [`/pages/project/project?assign=${item.clientMediaId}`])
  const selection = instance(picker)
  selection.onLoad({ assign: item.clientMediaId })
  selection.onShow()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(selection.data.navTitle, t('library.assign'))
  assert.equal(selection.data.assigning, true)
  selection.onSelectProject({ currentTarget: { dataset: { gi: 0, ii: 0 } } })
  assert.equal(back, 1)
  assert.equal(storage['awd.project'], undefined)
  assert.equal(listItems()[0].deviceId, project.deviceId)
  library.refresh()
  assert.equal(library.data.days.length, 0)
  assert.ok(library.data.projects.some((p: any) => p.id === project.projectUid))
})

test('unassigned photo/video local-save failures are visible and keep a temporary path for assignment', async () => {
  for (const kind of ['image', 'video'] as const) {
    await reset()
    const item = enqueueCapture(`/synthetic/${kind}`, kind, null)
    saves[0].fail()
    assert.equal(notices.length, 1)
    assert.equal(notices[0].content, t('capture.saveFailed'))
    assert.equal(listItems()[0].saved, false)
    assert.equal(listItems()[0].filePath, `/synthetic/${kind}`)
    const library = instance(gallery)
    library.refresh()
    assert.equal(library.data.days[0].items[0].errorText, t('capture.saveFailed'))
    assert.equal(assignCapture(item.clientMediaId, project), true)
    assert.equal(uploads.length, 1)
    assert.equal(uploads[0].filePath, `/synthetic/${kind}`)
  }
})

test('deleting a capture before its file-save callback cleans up the new file and never reports success', async () => {
  await reset()
  let result: boolean | undefined
  const item = enqueueCapture('/synthetic/photo', 'image', null, undefined, value => { result = value })
  removeItems([item.clientMediaId])
  saved()
  assert.equal(result, false)
  assert.deepEqual(listItems(), [])
  assert.deepEqual(removed, ['/synthetic/saved-0'])
  assert.equal(notices.length, 0)
  assert.equal(uploads.length, 0)
})
