import { test } from 'node:test'
import assert from 'node:assert/strict'
let definition: any
;(globalThis as any).Page = (page: any) => { definition = page }
;(globalThis as any).wx = { getStorageSync: () => undefined }
await import('../miniprogram/pages/login/login.ts')
function page() {
  return { ...definition, data: structuredClone(definition.data),
    setData(patch: any, done?: () => void) { Object.assign(this.data, patch); done?.() } }
}
test('login starts in password mode and registration/reset clicks clear passwords before navigation', () => {
  const paths: string[] = []
  ;(globalThis as any).wx = { navigateTo: (o: any) => paths.push(o.url) }
  const p = page()
  assert.equal(p.data.submitDisabled, true)
  p.onPhoneInput({ detail: { value: '13800000000' } })
  p.onPasswordInput({ detail: { value: '  synthetic password  ' } })
  assert.equal(p.data.password, '  synthetic password  ')
  assert.equal(p.data.submitDisabled, false)
  p.onRegister()
  assert.equal(p.data.password, '')
  assert.equal(p.data.submitDisabled, true)
  p.onReset()
  assert.deepEqual(paths, ['/pages/account/account?flow=register', '/pages/account/account?flow=reset'])
})
test('region change clears credentials and pending login prevents region/flow changes', () => {
  const p = page()
  p.data.phone = '13800000000'; p.data.password = 'synthetic'
  p.data.loggingIn = true
  p.onToggleRegion()
  assert.equal(p.data.region, 'cn')
  p.data.loggingIn = false
  p.onToggleRegion()
  assert.equal(p.data.region, 'intl')
  assert.equal(p.data.showLogin, false)
  assert.equal(p.data.phone, '')
  assert.equal(p.data.password, '')
})
test('review mode is explicit and never inferred from a six-digit password', () => {
  const p = page()
  p.onPhoneInput({ detail: { value: '13800000000' } })
  p.onPasswordInput({ detail: { value: '123456' } })
  assert.equal(p.data.reviewMode, false)
  p.onReview()
  assert.equal(p.data.reviewMode, true)
  assert.equal(p.data.password, '')
  p.onReview()
  assert.equal(p.data.reviewMode, false)
})
