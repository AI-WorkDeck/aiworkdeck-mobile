// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import test from 'node:test'
import assert from 'node:assert/strict'
let definition: any
;(globalThis as any).Page = (value: any) => { definition = value }
;(globalThis as any).wx = {getStorageSync: () => undefined}
await import('../miniprogram/pages/settings/settings.ts')
const settingsDefinition = definition
await import('../miniprogram/pages/postpaid/postpaid.ts')
const state = {
 billing: {policyVersion:'2026-11-04', accepted:false, acceptEnabled:true, unit:'credit_cent', cashCurrency:'CNY', creditLimitCents:14900, debtCents:100, availableCreditCents:14800, reservedCreditCents:0, remindAt:'2026-11-07T00:00:00Z', cleanupAt:'2026-11-09T00:00:00Z', storagePrice:{cashCentsPerGiBMonth:20,cashCurrency:'CNY',periodSeconds:2592000,gibBytes:1073741824},egressPrice:{cashCentsPerGiB:60,cashCurrency:'CNY',gibBytes:1073741824}},
 cloudAccess:{canUse:true,canWrite:true,canRead:true,reason:'ready',epoch:1,includedStorageBytes:0,cleanupEligible:false,notificationStatus:'none',frozen:false,cleanupState:'none'},
}
function setup(response = state) {
 let session='test-account'; let confirm=false
 const requests:any[]=[]
 ;(globalThis as any).wx={getStorageSync:(key:string)=>key==='awd.session'?session:undefined,
  request:(value:any)=>{if(value.url.endsWith('/auth/me')) {value.success({statusCode:200,data:{code:0,data:{id:71}}});return} if(value.url.endsWith('/cloud-state') && requests.length>1){value.success({statusCode:200,data:structuredClone(response)});return} requests.push(value);value.success({statusCode:200,data:structuredClone(response)})},
  setStorageSync:()=>{},
  showModal:async()=>({confirm}),
 }
 const page={...definition,data:structuredClone(definition.data),setData(value:any){Object.assign(this.data,value)}}
 return {page,requests,approve(){confirm=true},switchAccount(){session='other-account'}}
}
test('account panel never accepts automatically and rejection cannot create debt consent',async()=>{
 const {page,requests}=setup();await page.loadPostpaid()
 assert.equal(requests.length,1);assert.equal(requests[0].method,'GET')
 assert.equal(page.data.canAcceptPostpaid,true)
 assert.equal(page.data.hasDebt,true)
 await page.onAcceptPostpaid();assert.equal(requests.length,1)
})
test('explicit confirmation posts server policy version once without changing subscription identity',async()=>{
 const {page,requests,approve}=setup();await page.loadPostpaid();approve();await page.onAcceptPostpaid()
 assert.equal(requests.length,2);assert.equal(requests[1].method,'POST')
 assert.ok(requests[1].url.endsWith('/billing/postpaid-accept'))
 assert.deepEqual(requests[1].data,{policyVersion:'2026-11-04'})
})
test('old-account consent dialog cannot mutate the newly signed-in account',async()=>{
 const {page,requests,approve,switchAccount}=setup();await page.loadPostpaid();approve();switchAccount();await page.onAcceptPostpaid()
 assert.equal(requests.length,1)
})

test('paid frozen cloud requires explicit resume and never enables backup itself', async () => {
 const frozen = structuredClone(state); frozen.billing.accepted = true; frozen.billing.debtCents = 0
 frozen.cloudAccess.frozen = true; frozen.cloudAccess.canUse = false; frozen.cloudAccess.cleanupState = 'complete'
 const {page, requests, approve} = setup(frozen)
 await page.loadPostpaid(); assert.equal(page.data.canResumeCloud, true)
 await page.onResumeCloud(); assert.equal(requests.length, 1)
 approve(); await page.onResumeCloud()
 assert.equal(requests.length, 2); assert.ok(requests[1].url.endsWith('/billing/resume-cloud'))
 assert.deepEqual(requests[1].data, {policyVersion:'2026-11-04'})
 assert.ok(!requests.some(r => r.url.includes('backup-consent')))
})
test('resume cannot run with debt or a changed account and partial cleanup is not displayed as cleared', async () => {
 const frozen = structuredClone(state); frozen.billing.accepted = true; frozen.cloudAccess.frozen = true
 frozen.cloudAccess.canUse = false; frozen.cloudAccess.cleanupState = 'deleting'
 const {page, requests, approve, switchAccount} = setup(frozen)
 await page.loadPostpaid(); assert.equal(page.data.canResumeCloud, false)
 approve(); await page.onResumeCloud(); assert.equal(requests.length, 1)
 frozen.billing.debtCents = 0; await page.loadPostpaid(); assert.equal(page.data.canResumeCloud, true)
 switchAccount(); await page.onResumeCloud(); assert.equal(requests.length, 2)
})

test('settings shows postpaid as one status word and never mutates billing', async () => {
 const cases: [(s: typeof state) => void, string, boolean][] = [
  [() => {}, 'debt', true],
  [s => { s.billing.debtCents = 0 }, 'postpaid.status.off', false],
  [s => { s.billing.debtCents = 0; s.billing.accepted = true }, 'postpaid.status.on', false],
  [s => { s.billing.debtCents = 0; s.billing.accepted = true; s.cloudAccess.canUse = false }, 'postpaid.status.restricted', true],
 ]
 const { t } = await import('../miniprogram/utils/i18n.ts')
 for (const [mutate, expected, failed] of cases) {
  const response = structuredClone(state); mutate(response)
  const {requests} = setup(response)
  const page = {...settingsDefinition, data: structuredClone(settingsDefinition.data), setData(value: any) { Object.assign(this.data, value) }}
  await page.loadPostpaid()
  assert.equal(requests.length, 1); assert.equal(requests[0].method, 'GET')
  if (expected === 'debt') assert.notEqual(page.data.postpaidStatus, t('postpaid.status.off'))
  else assert.equal(page.data.postpaidStatus, t(expected as any))
  assert.equal(page.data.postpaidStatusFailed, failed)
 }
})
