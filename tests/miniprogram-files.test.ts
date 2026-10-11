import { test } from 'node:test'
import assert from 'node:assert/strict'
import { folderEntries, mergeLiveFiles, previewKind, unsupportedKey, type ProjectFile } from '../miniprogram/utils/project-files.ts'
import { previewQuote, pullPreview, cloudPreview } from '../miniprogram/utils/file-preview.ts'
import { chooseBackupConsent, promptBackupOnFirstUse } from '../miniprogram/utils/backup-consent.ts'
import { setSession } from '../miniprogram/utils/api.ts'

const file = (id: string, path: string, extra = {}): ProjectFile => ({ id, name: path.replace(/\\/g, '/').split('/').pop()!, path, size: 12, ...extra })
const project = { projectUid: 'p-uid', deviceId: 'desk', key: '1', name: 'Project', deviceName: null }

test('folder browsing preserves nested paths, empty directories and same-name files', () => {
  const files = [file('a', '合同/证据/1.pdf'), file('b', '其他\\1.pdf'), file('c', '空文件夹', { isFolder: true }), file('d', '1.pdf')]
  const root = folderEntries(files)
  assert.equal(root.filter(x => x.folder).length, 3)
  assert.equal(root.filter(x => !x.folder).length, 1)
  assert.equal(folderEntries(files, '合同')[0].path, '合同/证据')
  assert.equal(folderEntries(files, '合同/证据')[0].file?.id, 'a')
  assert.equal(folderEntries(files, '其他')[0].file?.id, 'b')
  assert.deepEqual(folderEntries(files, '空文件夹'), [])
})

test('mobile format allowlist excludes legacy office, archives, disguised extensions and platform-only formats', () => {
  for (const name of ['x.docx', 'x.pptx', 'x.xlsx', 'x.pdf', 'x.JPG', 'x.m4a', 'x.mp3', 'x.wav', 'x.aac', 'x.mp4']) {
    assert.ok(previewKind(file(name, name)), name)
  }
  for (const name of ['x.doc', 'x.xls', 'x.ppt', 'x.zip', 'x.txt', 'x.pdf.exe', 'x.mov', 'x.heic', 'x.caf', 'x.webp']) {
    assert.equal(previewKind(file(name, name)), null, name)
  }
  assert.equal(unsupportedKey(file('1', 'x.heic')), 'files.platformUnsupported')
  assert.equal(unsupportedKey(file('1', 'x.zip')), 'files.unsupported')
})

function fakeWx() {
  const storage = new Map<string, any>([['awd.session', 'session-a']])
  const requests: any[] = []
  const removed: string[] = []
  let consent = { enabled: false, decided: false, subscriptionActive: true, consentVersion: null as string | null }
  let choice = true
  let failPut = false
  let lostPull = false
  let downloads = 0
  let modals = 0
  const wx = {
    getStorageSync: (key: string) => storage.get(key),
    setStorageSync: (key: string, value: unknown) => storage.set(key, value),
    removeStorageSync: (key: string) => storage.delete(key),
    showToast: () => {},
    showModal: async () => { modals++; return { confirm: choice, cancel: !choice } },
    request: (opts: any) => {
      requests.push(opts)
      if (opts.url.endsWith('/backup-consent')) {
        if (opts.method === 'PUT') {
          if (failPut) { opts.fail(); return }
          consent = { ...consent, ...opts.data, decided: true }
        }
        opts.success({ statusCode: 200, data: consent }); return
      }
      if (opts.url.endsWith('/preview/pull')) {
        if (lostPull) { lostPull = false; opts.fail(); return }
        opts.success({ statusCode: 200, data: { code: 0, id: 7 } }); return
      }
      if (opts.url.endsWith('/transfer/7')) {
        opts.success({ statusCode: 200, data: { code: 0, transfer: { id: 7, kind: 'PULL', status: 'STAGED', fileSize: 12 } } }); return
      }
      if (opts.url.endsWith('/ack')) { opts.success({ statusCode: 200, data: { code: 0 } }); return }
      if (opts.url.includes('/quote?')) { opts.success({ statusCode: 200, data: { code: 0, credits: 1 } }); return }
      throw Error('Unexpected request: ' + opts.url)
    },
    downloadFile: (opts: any) => {
      downloads++
      const task = { abort() {}, onHeadersReceived(fn: any) { fn({ header: { 'Content-Type': 'application/octet-stream' } }) }, onProgressUpdate() {} }
      queueMicrotask(() => opts.success({ statusCode: 200, tempFilePath: '/temp.pdf' }))
      return task
    },
    getFileSystemManager: () => ({
      getFileInfo: (opts: any) => opts.success({ size: 12 }),
      saveFile: (opts: any) => opts.success({ savedFilePath: '/saved.pdf' }),
      unlink: (opts: any) => removed.push(opts.filePath),
    }),
  }
  ;(globalThis as any).wx = wx
  return { storage, requests, removed, setChoice: (v: boolean) => { choice = v }, setFailPut: (v: boolean) => { failPut = v },
    setConsent: (v: Partial<typeof consent>) => { consent = { ...consent, ...v } }, losePull: () => { lostPull = true },
    get consent() { return consent }, get downloads() { return downloads }, get modals() { return modals } }
}

test('unsupported files never quote, create a pull or download bytes', async () => {
  const mock = fakeWx()
  for (const name of ['script.sh', 'archive.zip', 'note.txt', 'old.doc', 'apple.heic']) {
    const unsupported = file('1', name)
    await assert.rejects(previewQuote(unsupported))
    await assert.rejects(pullPreview(project, unsupported, () => true))
    await assert.rejects(cloudPreview(project, unsupported))
  }
  assert.equal(mock.requests.length, 0)
  assert.equal(mock.downloads, 0)
})

test('cloud content requires both subscription and affirmative consent before any byte transfer', async () => {
  for (const consent of [{ enabled: false, subscriptionActive: true }, { enabled: true, subscriptionActive: false }]) {
    const mock = fakeWx(); mock.setConsent(consent)
    await assert.rejects(cloudPreview(project, file('1', 'a.pdf', { uid: 'uid' })))
    assert.equal(mock.downloads, 0)
  }
  const mock = fakeWx(); mock.setConsent({ enabled: true, subscriptionActive: true })
  assert.equal(await cloudPreview(project, file('1', 'a.pdf', { uid: 'uid' })), '/temp.pdf')
  assert.equal(mock.downloads, 1)
})

test('lost charged response retries the same UUID and durable preview is saved before ACK', async () => {
  const mock = fakeWx(); mock.losePull()
  const item = file('1', 'a.pdf')
  await assert.rejects(pullPreview(project, item, () => true))
  assert.equal(await pullPreview(project, item, () => true), '/saved.pdf')
  const pulls = mock.requests.filter(x => x.url.endsWith('/preview/pull'))
  assert.equal(pulls.length, 2)
  assert.equal(pulls[0].data.requestId, pulls[1].data.requestId)
  assert.equal(mock.downloads, 1)
  assert.equal(await pullPreview(project, item, () => true), '/saved.pdf')
  assert.equal(mock.downloads, 1)
  setSession('session-b')
  assert.deepEqual(mock.removed, ['/saved.pdf'])
  assert.equal(mock.storage.has('awd.filePulls'), false)
})

test('consent decline is persisted, non-subscribers cannot enable, failed writes remain undecided', async () => {
  let mock = fakeWx(); mock.setChoice(false)
  await chooseBackupConsent(mock.consent)
  assert.equal(mock.consent.enabled, false)
  assert.equal(mock.consent.decided, true)
  mock = fakeWx(); mock.setConsent({ subscriptionActive: false })
  await chooseBackupConsent(mock.consent)
  assert.equal(mock.consent.enabled, false)
  mock = fakeWx(); mock.setFailPut(true)
  await assert.rejects(chooseBackupConsent(mock.consent))
  assert.equal(mock.consent.decided, false)
  await promptBackupOnFirstUse()
  assert.equal(mock.modals, 2)
  assert.equal(mock.consent.decided, false)
  mock.setFailPut(false)
  await promptBackupOnFirstUse()
  assert.equal(mock.consent.enabled, true)
  await promptBackupOnFirstUse()
  assert.equal(mock.modals, 3)
})

test('live listing merges catalog sources without hiding cloud-only or second desktop files', () => {
  const cached = [file('local-a', 'a.pdf', { uid: 'canonical-a', deviceId: 'desk', projectKey: '1', source: 'backup' }),
    file('cloud', 'cloud.pdf', { uid: 'cloud', source: 'cloud' }),
    file('other', 'other.pdf', { deviceId: 'desk-b', projectKey: '2', source: 'desktop' })]
  const merged = mergeLiveFiles(cached, [file('local-a', 'folder/a.pdf', { deviceId: 'desk', projectKey: '1', source: 'desktop', online: true })])
  assert.equal(merged.length, 3)
  assert.equal(merged[0].source, 'desktop')
  assert.equal(merged[0].uid, 'canonical-a')
  assert.equal(merged[0].path, 'folder/a.pdf')
  assert.equal(merged[1].source, 'cloud')
  assert.equal(merged[2].deviceId, 'desk-b')
})
