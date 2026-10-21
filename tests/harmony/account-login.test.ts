import { test } from 'node:test'
import assert from 'node:assert/strict'
// @ts-ignore ArkTS pure decoder is loaded by node-ts-resolve.mjs.
import { decodeLoginResult } from '../../harmony/entry/src/main/ets/services/ApiTypes.ets'

test('harmony login decoder preserves existing identity and rejects setup or incomplete responses', () => {
  const user = { id: 71, username: 'synthetic-existing', displayName: 'Test' }
  assert.equal(decodeLoginResult({ sessionId: 'synthetic-device', user }).user.id, 71)
  for (const response of [
    { passwordSetupRequired: true, setupToken: 'synthetic-setup' },
    { sessionId: '' },
    { sessionId: 'synthetic-device' },
    { sessionId: 'synthetic-device', user: { id: 71 } },
    { sessionId: 'synthetic-device', user: { ...user, id: 0 } },
  ]) assert.throws(() => decodeLoginResult(response))
})
