import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  phaseOf, stateText, dotClass, tallyOf, tallyTotal, projectId,
  groupByDay, deleteWarning, projectsIn, PHASE_LABEL, getPhaseLabel,
} from '../miniprogram/utils/phase.ts'
import { setLocale } from '../miniprogram/utils/i18n.ts'

test('phase mapping', () => {
  assert.equal(phaseOf('waiting'), 'uploading')
  assert.equal(phaseOf('uploading'), 'uploading')
  assert.equal(phaseOf('failed'), 'uploading')
  assert.equal(phaseOf('uploaded'), 'staged')
  assert.equal(phaseOf('arrived'), 'landed')
})

test('state text and dot class', () => {
  assert.equal(stateText('waiting'), '上传中')
  assert.equal(stateText('failed'), '上传失败')
  assert.equal(stateText('uploaded'), '已暂存 · 等待桌面端接收')
  assert.equal(stateText('arrived'), '已落盘')
  assert.equal(dotClass('waiting'), 'dot--waiting')
  assert.equal(dotClass('uploading'), 'dot--waiting')
  assert.equal(dotClass('uploaded'), 'dot--moving')
  assert.equal(dotClass('arrived'), 'dot--arrived')
  assert.equal(dotClass('failed'), 'dot--failed')
})

test('tally counts failed inside uploading', () => {
  const t = tallyOf([
    { state: 'waiting' }, { state: 'failed' }, { state: 'uploading' },
    { state: 'uploaded' }, { state: 'arrived' }, { state: 'arrived' },
  ])
  assert.deepEqual(t, { uploading: 3, failed: 1, staged: 1, landed: 2 })
  assert.equal(tallyTotal(t), 6)
})

test('projectId joins deviceId and key', () => {
  assert.equal(projectId({ deviceId: 'd', projectKey: '7' }), 'd:7')
})

test('groupByDay newest first with title', () => {
  const at = (m: number, d: number, h: number) => new Date(2026, m - 1, d, h).getTime()
  const days = groupByDay([
    { createdAt: at(9, 1, 10) }, { createdAt: at(9, 2, 9) }, { createdAt: at(9, 2, 15) },
  ])
  assert.equal(days.length, 2)
  assert.equal(days[0].title, '9月2日 · 2 件')
  assert.deepEqual(days[0].items.map((i) => i.createdAt), [at(9, 2, 15), at(9, 2, 9)])
  assert.equal(days[1].title, '9月1日 · 1 件')
})

test('deleteWarning by worst phase', () => {
  assert.equal(deleteWarning(['arrived', 'arrived']), '删除 2 件本地原图？电脑上已有副本。')
  assert.equal(deleteWarning(['arrived', 'uploaded']),
    '其中 1 件电脑还没取回。中转区 30 天后清理，电脑若未及时接收，这些影像将无法找回。')
  assert.equal(deleteWarning(['uploaded', 'failed', 'waiting']),
    '其中 2 件还没送出去。删了就没了，无法找回。')
})

test('projectsIn current first, others by name', () => {
  const cur = { deviceId: 'd', key: '1', name: '甲' }
  const ps = projectsIn([
    { deviceId: 'd', projectKey: '3', projectName: '丙' },
    { deviceId: 'd', projectKey: '2', projectName: '乙' },
    { deviceId: 'd', projectKey: '1', projectName: '甲' },
  ], cur)
  // 丙(bǐng) 排在 乙(yǐ) 前：按拼音与按码点结论一致，小程序运行时没有 ICU 也不变
  assert.deepEqual(ps.map((p) => p.id), ['d:1', 'd:3', 'd:2'])
  assert.deepEqual(projectsIn([], cur), [{ id: 'd:1', name: '甲' }])
})

test('PHASE_LABEL and getPhaseLabel resolve dynamically across locale changes', () => {
  try {
    setLocale('zh-Hans')
    assert.equal(PHASE_LABEL.uploading, '上传中')
    assert.equal(PHASE_LABEL.staged, '已暂存')
    assert.equal(PHASE_LABEL.landed, '已落盘')
    assert.equal(getPhaseLabel('uploading'), '上传中')

    setLocale('en')
    assert.equal(PHASE_LABEL.uploading, 'Uploading')
    assert.equal(PHASE_LABEL.staged, 'Staged')
    assert.equal(PHASE_LABEL.landed, 'Landed')
    assert.equal(getPhaseLabel('uploading'), 'Uploading')
  } finally {
    setLocale('zh-Hans')
  }
})
