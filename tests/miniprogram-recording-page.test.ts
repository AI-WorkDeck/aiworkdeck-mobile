import { test } from 'node:test'
import assert from 'node:assert/strict'
import { t } from '../miniprogram/utils/i18n.ts'

let definition: any
let storage: Record<string, any> = {}
let save: any
const handlers: Record<string, (result?: any) => void> = {}
const on = (name: string) => (cb: any) => { handlers[name] = cb }
const manager = { start: () => handlers.start(), stop() {},
  onPause: on('pause'), onResume: on('resume'), onFrameRecorded: on('frame'),
  onStart: on('start'), onStop: on('stop'), onError: on('error'), onInterruptionBegin: on('interruption') }
const modals: any[] = []
const redirects: string[] = []
;(globalThis as any).Page = (page: any) => { definition = page }
;(globalThis as any).getApp = () => ({ globalData: { metrics: {} } })
;(globalThis as any).wx = {
  getStorageSync: (key: string) => storage[key],
  setStorageSync: (key: string, value: any) => { storage[key] = value },
  getRecorderManager: () => manager,
  getFileSystemManager: () => ({ saveFile: (o: any) => { save = o } }),
  uploadFile: (o: any) => { o.success({ statusCode: 200, data: JSON.stringify({ code: 0 }) }); return {} },
  request: (o: any) => o.success({ statusCode: 200, data: { enabled: false, decided: true, subscriptionActive: false } }),
  authorize: (o: any) => o.success(),
  showModal: (o: any) => { modals.push(o) },
  reLaunch: (o: any) => redirects.push(o.url),
  showToast() {}, vibrateShort() {}, nextTick: (cb: () => void) => cb(),
}
await import('../miniprogram/pages/index/index.ts')
function page() {
  const instance = { ...definition, data: structuredClone(definition.data),
    setData(patch: any) { Object.assign(this.data, patch) }, refresh() {},
    unsubscribe() {}, startPolling() {}, startWatermark() {}, startRecordTimer() {} }
  instance.onLoad()
  return instance
}

test('fresh unauthenticated home reaches login without mounting camera or exposing recording controls', () => {
  storage = {}; redirects.length = 0
  const instance = page()
  instance.onShow()
  assert.deepEqual(redirects, ['/pages/login/login'])
  assert.equal(instance.visible, false)
  assert.equal(instance.data.recording, false)
  assert.equal(instance.data.cameraMounted, false)
})

test('home audio action keeps an interrupted recording notice across hide and page recreation', async () => {
  storage = { 'awd.session': 'synthetic-session', 'awd.project': { deviceId: 'synthetic', key: '1', name: '合成项目' } }
  modals.length = 0
  const original = page()
  original.onShow()
  original.onSwitchMode({ currentTarget: { dataset: { mode: 'audio' } } })
  original.onShutter()
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(original.data.recording, true)
  assert.equal(original.data.recordInterruptedText, t('rec.interruption.saving'))
  original.onHide()
  original.onUnload()
  handlers.interruption()
  handlers.stop({ tempFilePath: '/synthetic/audio.mp3', duration: 5000, fileSize: 1024 })
  assert.equal(modals.length, 0)
  save.success({ savedFilePath: '/synthetic/saved.mp3' })
  assert.equal(modals.length, 0)
  const replacement = page()
  replacement.onShow()
  assert.equal(replacement.data.recording, false)
  assert.equal(modals.length, 1)
  assert.equal(modals[0].content, t('rec.interruption.saved'))
  assert.equal(modals[0].showCancel, false)
  replacement.showRecordingNotice()
  assert.equal(modals.length, 1)
  replacement.onHide()
  replacement.onUnload()
})

test('camera interruption remounts while visible but never reattaches a hidden page', () => {
  const instance = page()
  instance.visible = true
  instance.onReady()
  instance.onCameraReady()
  instance.onCameraStop()
  assert.equal(instance.data.cameraMounted, true)
  assert.equal(instance.data.cameraState, 'pending')
  instance.onHide()
  instance.onCameraStop()
  assert.equal(instance.data.cameraMounted, false)
})

test('video pause saves the current segment before exposing resume and resume failure stays paused for retry', async () => {
  storage = {}; modals.length = 0
  const instance = page()
  instance.data.mode = 'video'
  let startOptions: any, stopOptions: any
  instance.camera = () => ({ startRecord(o: any) { startOptions = o }, stopRecord(o: any) { stopOptions = o } })
  instance.startVideo()
  startOptions.success()
  instance.onPauseResume()
  assert.equal(instance.data.pausePending, true)
  assert.equal(instance.data.recordPaused, false)
  stopOptions.success({ tempVideoPath: '/synthetic/segment.mp4' })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(instance.data.recordPaused, false)
  save.success({ savedFilePath: '/synthetic/saved-segment.mp4' })
  assert.equal(instance.data.recordPaused, true)
  instance.onPauseResume()
  startOptions.fail()
  assert.equal(instance.data.recording, true)
  assert.equal(instance.data.recordPaused, true)
  assert.equal(instance.data.pausePending, false)
  assert.equal(instance.data.recordSegment, 1)
  instance.onPauseResume()
  startOptions.success()
  assert.equal(instance.data.recordPaused, false)
  assert.equal(instance.data.recordSegment, 2)
  instance.stopVideo()
  stopOptions.success({ tempVideoPath: '/synthetic/segment2.mp4' })
  await new Promise(resolve => setImmediate(resolve))
  save.success({ savedFilePath: '/synthetic/saved-segment2.mp4' })
  assert.equal(instance.data.recording, false)
})
