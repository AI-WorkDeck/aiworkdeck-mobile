// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import test from 'node:test'
import assert from 'node:assert/strict'
import { cloudCanRead, cloudCanWrite, cloudCanUse, type CloudAccess } from '../miniprogram/utils/cloud-access.ts'
const access: CloudAccess = {canUse: true, canWrite: true, canRead: true, reason: 'ready', epoch: 1, includedStorageBytes: 0, cleanupEligible: false, notificationStatus: 'none', frozen: false, cleanupState: 'none'}
test('non subscribers receive authoritative cloud permissions without becoming subscribers', () => {
 const value = {subscriptionActive: false, cloudAccess: access}
 assert.equal(cloudCanUse(value), true); assert.equal(cloudCanWrite(value), true); assert.equal(cloudCanRead(value), true)
 assert.equal(value.subscriptionActive, false)
})
test('restricted subscriber can still read but cannot start paid work or upload', () => {
 const value = {subscriptionActive: true, cloudAccess: {...access, canUse: false, canWrite: false}}
 assert.equal(cloudCanUse(value), false); assert.equal(cloudCanWrite(value), false); assert.equal(cloudCanRead(value), true)
})
test('cleanup denies access regardless of stale subscription; absent fields use legacy response only', () => {
 const value = {subscriptionActive: true, cloudAccess: {...access, canUse: false, canWrite: false, canRead: false, cleanupState: 'complete'}}
 assert.equal(cloudCanUse(value), false); assert.equal(cloudCanRead(value), false); assert.equal(cloudCanWrite(value), false)
 assert.equal(cloudCanRead({subscriptionActive: true}), true)
 assert.equal(cloudCanRead({subscriptionActive: false}), false)
})
