import { test, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { accountLogin } from '../miniprogram/utils/api.ts'

const previousWx = (globalThis as any).wx
afterEach(() => { (globalThis as any).wx = previousWx })
function mock(response: unknown, statusCode = 200) {
  const storage = new Map<string, unknown>()
  const requests: any[] = []
  ;(globalThis as any).wx = {
    getStorageSync: (k: string) => storage.get(k),
    setStorageSync: (k: string, v: unknown) => storage.set(k, v),
    removeStorageSync: (k: string) => storage.delete(k),
    showToast: () => {}, reLaunch: () => {},
    request: (options: any) => { requests.push(options); options.success({statusCode, data: response}) },
  }
  return { storage, requests }
}
test('password sign-in preserves the original mobile identity and password whitespace', async () => {
  const user = { id: 71, username: 'synthetic-existing-user', displayName: 'Test' }
  const { storage, requests } = mock({ code: 0, data: { sessionId: 'synthetic-device-token', user } })
  const result = await accountLogin('13800000000', '  synthetic password  ')
  assert.equal(requests.length, 1)
  assert.ok(requests[0].url.endsWith('/api/auth/account-login'))
  assert.deepEqual(requests[0].data, { account: '13800000000', password: '  synthetic password  ' })
  assert.equal(result.user.id, 71)
  assert.deepEqual(storage.get('awd.user'), user)
  assert.equal(storage.get('awd.session'), 'synthetic-device-token')
  assert.equal([...storage.values()].some(v => String(v).includes('synthetic password')), false)
})
test('setup challenge is not a mobile session', async () => {
  const { storage } = mock({ code: 0, data: { passwordSetupRequired: true, setupToken: 'synthetic-setup' } })
  await assert.rejects(accountLogin('13800000000', 'password'))
  assert.equal(storage.size, 0)
})
test('missing identity, blank session, rejected password and gateway failure never persist login', async () => {
  for (const [status, response] of [
    [200, { code: 0, data: { sessionId: 'device-token' } }],
    [200, { code: 0, data: { sessionId: '', user: { id: 71, username: 'test', displayName: 'Test' } } }],
    [200, { code: 1, message: 'Incorrect password' }],
    [502, 'Bad Gateway'],
  ] as const) {
    const { storage } = mock(response, status)
    await assert.rejects(accountLogin('13800000000', 'synthetic'))
    assert.equal(storage.size, 0)
  }
})
