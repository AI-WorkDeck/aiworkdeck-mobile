import { test } from 'node:test'
import assert from 'node:assert/strict'
import { accountFlowUrl, accountReferral } from '../miniprogram/utils/account-flow.ts'

test('registration preserves a public referral tag through a fixed website URL', () => {
  assert.equal(accountReferral('u-synthetic-author'), 'u-synthetic-author')
  assert.equal(accountFlowUrl('register', 'u-synthetic-author'), 'https://aiworkdeck.com/zh/account?flow=register&ref=u-synthetic-author')
})
test('reset and untrusted URL/ref values cannot inject credentials or another origin', () => {
  assert.equal(accountFlowUrl('reset', 'u-synthetic-author'), 'https://aiworkdeck.com/zh/account?flow=reset')
  for (const ref of ['https://example.invalid', 'u-test&setupToken=secret', 'u-XSS', 'u-' + 'a'.repeat(31), undefined]) {
    assert.equal(accountReferral(ref), '')
    assert.equal(accountFlowUrl('https://example.invalid', ref), 'https://aiworkdeck.com/zh/account?flow=register')
  }
})
