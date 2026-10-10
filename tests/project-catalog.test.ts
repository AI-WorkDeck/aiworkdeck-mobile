// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fromCatalog, sameProject } from '../miniprogram/utils/project-catalog.ts'
import { decodeCatalog, decodeRelayProject, decodeSubscriptionBalance, decodeMediaUsage } from '../harmony/entry/src/main/ets/services/ApiTypes.ets'
import { sameProject as sameHarmonyProject, projectId } from '../harmony/entry/src/main/ets/model/Capture.ets'
const fixture = JSON.parse(readFileSync(new URL('../contract/fixtures/project-catalog.json', import.meta.url), 'utf8'))
for (const [name, decode, same] of [
  ['miniprogram', (v: any) => v.map(fromCatalog), sameProject],
  ['harmony', decodeCatalog, sameHarmonyProject],
] as const) {
  test(`${name}: canonical identity retains same-name separate projects and cloud-only source`, () => {
    const projects = decode(fixture)
    assert.equal(projects.length, 2)
    assert.equal(projects[0].deviceId, 'desk-b')
    assert.equal(projects[1].deviceId, 'cloud')
    assert.equal(projects[0].projectUid, fixture[0].projectUid)
    assert.equal(same(projects[0], projects[1]), false)
    assert.equal(same(projects[0], {deviceId:'desk-a', key:'7', name:'Old name', deviceName:null}), true)
    assert.equal(same(projects[0], {deviceId:'desk-c', key:'7', name:'Same name', deviceName:null}), false)
  })
}
test('harmony: persisted upload location is retained with its canonical identity', () => {
  const saved = decodeRelayProject({deviceId:'desk-a', key:'7', name:'Old', projectUid:fixture[0].projectUid,
    locations:fixture[0].locations})!
  assert.equal(saved.deviceId, 'desk-a')
  assert.equal(projectId(saved), fixture[0].projectUid)
})

for (const [name, decode] of [['miniprogram', (v: any) => v.map(fromCatalog)], ['harmony', decodeCatalog]] as const) {
  test(`${name}: archive-only cloud location does not silently replace desktop capture destination`, () => {
    const entry = {...fixture[0], locations:[...fixture[0].locations,
      {kind:'cloud', deviceId:'cloud', key:'99', online:true, archiveOnly:true}]}
    assert.equal(decode([entry])[0].deviceId, 'desk-b')
  })
}

test('harmony: subscription allowance never replaces cash or unknown storage quota', () => {
  const sub = {active:true, availableCents:2500, monthlyLimitCents:14900, monthlyUsedCents:2000,
    weeklyLimitCents:4500, weeklyUsedCents:2000}
  assert.deepEqual(decodeSubscriptionBalance({balanceCents:0, subscription:sub}), sub)
  assert.equal(decodeSubscriptionBalance({balanceCents:0}), null)
  assert.throws(() => decodeSubscriptionBalance({subscription:{active:true}}))
  const usage = decodeMediaUsage({usedBytes:9, quotaBytes:209715200, persistentUsedBytes:42,
    persistentQuotaBytes:null, persistentQuotaAvailable:false})
  assert.equal(usage.persistentUsedBytes, 42)
  assert.equal(usage.persistentQuotaBytes, undefined)
  assert.equal(usage.persistentQuotaAvailable, false)
})
