// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import { test, afterEach } from 'node:test'
import assert from 'node:assert/strict'
import { captureOrganizationEnabled, setCaptureOrganizationEnabled, setSession, uploadMedia, captureOrganizationCaption } from '../miniprogram/utils/api.ts'
// @ts-ignore ArkTS decoder is loaded by the project test loader.
import { decodeUploadResult } from '../harmony/entry/src/main/ets/services/ApiTypes.ets'

const previous = (globalThis as any).wx
afterEach(() => { (globalThis as any).wx = previous })
function fixture(body: unknown = { code: 0, id: 1, clientMediaId: 'synthetic', delivered: false }) {
  const storage = new Map<string, unknown>([['awd.session', 'synthetic-session-a'], ['awd.user', { id: 71 }]])
  const requests: any[] = []
  ;(globalThis as any).wx = {
    getStorageSync: (key: string) => storage.get(key),
    setStorageSync: (key: string, value: unknown) => storage.set(key, value),
    removeStorageSync: (key: string) => storage.delete(key),
    getFileSystemManager: () => ({ unlink: () => {} }),
    uploadFile: (options: any) => {
      requests.push(options)
      queueMicrotask(() => options.success({ statusCode: 200, data: JSON.stringify(body) }))
      return { onProgressUpdate: () => {} }
    },
  }
  return { storage, requests }
}
const capture = { filePath: '/synthetic/original.m4a', deviceId: 'desktop-a', projectKey: 'project-a', clientMediaId: 'synthetic', fileName: 'original.m4a', mediaType: 'audio' as const, capturedAt: '2026-10-30T10:00:00+08:00' }

test('default-off sends no consent, enabling sends consent for audio without altering original identity', async () => {
  const { requests } = fixture()
  assert.equal(captureOrganizationEnabled(), false)
  assert.equal(await uploadMedia(capture), undefined)
  assert.equal(requests[0].formData.organize, 'false')
  setCaptureOrganizationEnabled(true)
  assert.equal(captureOrganizationEnabled(), true)
  const result = await uploadMedia(capture)
  assert.deepEqual(result, { state: 'unknown' }) // Old server cannot masquerade as success.
  assert.equal(requests[1].formData.organize, 'true')
  assert.equal(requests[1].filePath, capture.filePath)
  assert.equal(requests[1].formData.fileName, capture.fileName)
  assert.equal(requests[1].formData.clientMediaId, capture.clientMediaId)
  assert.ok(requests[1].timeout >= 90000)
})

test('changing session or account cannot inherit capture AI consent', () => {
  const { storage } = fixture()
  setCaptureOrganizationEnabled(true)
  storage.set('awd.user', { id: 72 })
  assert.equal(captureOrganizationEnabled(), false)
  storage.set('awd.user', { id: 71 })
  assert.equal(captureOrganizationEnabled(), true)
  setSession('synthetic-session-b')
  assert.equal(captureOrganizationEnabled(), false)
  setCaptureOrganizationEnabled(true)
  setSession(null)
  assert.equal(captureOrganizationEnabled(), false)
})

test('ready result preserves archived name while failed pre-read remains a successful original upload', async () => {
  const organization = { state: 'ready', originalName: 'original.m4a', fileName: 'Interview.m4a', archiveName: 'Interview-uuid.m4a', tags: ['Interview'] }
  fixture({ code: 0, organization })
  setCaptureOrganizationEnabled(true)
  assert.deepEqual(await uploadMedia(capture), organization)
  fixture({ code: 0, organization: { state: 'failed', originalName: 'original.m4a', fileName: 'original.m4a', tags: [] } })
  setCaptureOrganizationEnabled(true)
  const failed = await uploadMedia(capture)
  assert.equal(failed?.state, 'failed')
  assert.notEqual(captureOrganizationCaption(failed!), captureOrganizationCaption(organization))
})

test('Harmony decodes optional organization without breaking old upload replies', () => {
  assert.equal(decodeUploadResult({ code: 0 }, 'synthetic').organization, undefined)
  const organization = { state: 'ready', fileName: 'License.jpg', archiveName: 'License-uuid.jpg', tags: ['License'], fields: { subject: 'Synthetic company' } }
  const actual = decodeUploadResult({ code: 0, organization }, 'synthetic').organization
  assert.equal(actual.archiveName, organization.archiveName)
  assert.deepEqual(actual.tags, ['License'])
})
