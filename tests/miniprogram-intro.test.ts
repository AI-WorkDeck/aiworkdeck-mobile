import { test } from 'node:test'
import assert from 'node:assert/strict'
let definition: any
;(globalThis as any).Page = (value: any) => { definition = value }
await import('../miniprogram/pages/start/start.ts')
const intro = definition
await import('../miniprogram/pages/personal/personal.ts')
const personal = definition

test('signed-out entry shows an overview without requesting account or platform authorization', () => {
  const routes: string[] = []
  ;(globalThis as any).wx = {
    getStorageSync: () => undefined,
    reLaunch: ({ url }: any) => routes.push(url),
    navigateTo: ({ url }: any) => routes.push(url),
    getSystemInfoSync: () => ({ language: 'en' }),
    request() { assert.fail('overview must not request cloud data') },
    login() { assert.fail('overview must not authorize WeChat') },
  }
  ;(globalThis as any).getApp = () => ({ globalData: { metrics: {} } })
  personal.onShow.call({})
  assert.deepEqual(routes, ['/pages/start/start'])
  const page = { ...intro, data: {}, setData(value: any) { Object.assign(this.data, value) } }
  page.onLoad({ ref: 'synthetic-referral' }); page.onShow()
  assert.equal(routes.length, 1)
  assert.ok(page.data.hint)
  page.onEnterApp()
  assert.equal(routes.at(-1), '/pages/login/login')
  page.onRegister()
  assert.ok(routes.at(-1)?.startsWith('/pages/account/account?flow=register'))
})
