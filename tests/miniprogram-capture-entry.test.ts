import { test } from 'node:test'
import assert from 'node:assert/strict'

let definition: any
;(globalThis as any).Page = (page: any) => { definition = page }
;(globalThis as any).wx = { getStorageSync: () => undefined }
await import('../miniprogram/pages/index/index.ts')

function page() {
  return { ...definition, data: structuredClone(definition.data), setData(patch: any) { Object.assign(this.data, patch) } }
}

test('camera first entry mounts only after ready and visible, without a mode round trip', () => {
  const instance = page()
  instance.visible = true
  instance.mountCamera()
  assert.equal(instance.data.cameraMounted, false)
  instance.onReady()
  assert.equal(instance.data.cameraMounted, true)
  assert.equal(instance.data.mode, 'photo')
  instance.unmountCamera()
  instance.visible = false
  instance.mountCamera()
  assert.equal(instance.data.cameraMounted, false)
})

test('logged-in capture remains the landing page with no selected project', () => {
  const redirects: string[] = []
  ;(globalThis as any).wx = {
    getStorageSync: (key: string) => key === 'awd.session' ? 'session' : undefined,
    reLaunch: (opts: any) => redirects.push(opts.url),
    request: (opts: any) => opts.success({ statusCode: 200, data: { enabled: false, decided: true, subscriptionActive: false } }),
  }
  const instance = page()
  instance.refresh = () => {}
  instance.unsubscribe = () => {}
  instance.startPolling = () => {}
  instance.startWatermark = () => {}
  instance.onShow()
  assert.deepEqual(redirects, [])
  assert.equal(instance.visible, true)
  assert.ok(instance.data.project.name)
  instance.visible = false
})

test('shutter with no project captures locally without requiring project selection', () => {
  ;(globalThis as any).wx = { getStorageSync: () => undefined }
  const instance = page()
  let captured: unknown = 'not called'
  instance.data.cameraState = 'ready'
  ;(globalThis as any).wx.vibrateShort = () => {}
  instance.takePhoto = (project: unknown) => { captured = project }
  instance.onShutter()
  assert.equal(captured, null)
})
