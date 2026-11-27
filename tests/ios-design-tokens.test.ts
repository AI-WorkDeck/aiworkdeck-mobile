// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// X27: the Personal, Workspace and Firm screens (and Home's dark records strip) sit on the design
// tokens, not on iOS system greys, so they match Home and Library in light and dark mode.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const read = (path: string) => readFileSync(new URL(`../ios/${path}`, import.meta.url), 'utf8')

const VIEWS = [
  'Sources/Features/Personal/PersonalWorkspaceView.swift',
  'Sources/Features/Workspace/WorkspaceView.swift',
  'Sources/Features/Firm/FirmInboxView.swift',
  'Sources/Features/Firm/FirmSheets.swift',
  'Sources/Features/Home/HomeView.swift',
]

const FORBIDDEN = [
  'Color(.system', 'Color(.secondary', 'Color(.tertiary', 'Color(.separator',
  '.foregroundStyle(.secondary)', '.foregroundStyle(.tertiary)', '.foregroundStyle(.primary)',
  'Color.secondary', 'Color.primary', '.system(size:',
]

// Only Home's camera chrome keeps fixed sizes: SF Symbols drawn inside fixed 48pt / 74pt circles and a
// 44pt thumbnail placeholder, plus the mode switcher under the shutter. Scaling them with Dynamic Type
// would overflow their shapes; the camera is outside the X27 screens.
const ALLOWED: Record<string, string[]> = {
  'Sources/Features/Home/HomeView.swift': [
    '.font(.system(size: 13, weight: mode == m ? .semibold : .regular))',
    '.font(.system(size: 13))',
    '.font(.system(size: 22))',
    '.font(.system(size: 30, weight: .semibold))',
  ],
}

export function offTokenLines(path: string, source: string): string[] {
  const allowed = ALLOWED[path] ?? []
  return source.split('\n').flatMap((line, i) => {
    const code = line.replace(/\/\/.*$/, '').trim()
    if (!FORBIDDEN.some(p => code.includes(p)) || allowed.includes(code)) return []
    return [`${path}:${i + 1}: ${code}`]
  })
}

test('Personal, Workspace, Firm and Home records use design tokens, not system greys or fixed sizes', () => {
  assert.deepEqual(VIEWS.flatMap(path => offTokenLines(path, read(path))), [])
})

test('the scan catches the system colours and fixed sizes it guards against', () => {
  const sample = [
    'static let card = Color(.secondarySystemGroupedBackground)',
    'Text(a).foregroundStyle(Color(.tertiaryLabel))',
    'Text(b).foregroundStyle(.secondary)',
    'Text(c).foregroundStyle(Color.primary)',
    'Text(d).font(.system(size: 15))',
    '// Color.secondary in a comment is fine',
  ].join('\n')
  assert.equal(offTokenLines('x.swift', sample).length, 5)
})

test('Firm colours keep following light and dark mode through token pairs', () => {
  const firm = read('Sources/Features/Firm/FirmInboxView.swift')
  const block = firm.slice(firm.indexOf('enum FirmColor'))
  for (const name of ['accent', 'waiting', 'urgent', 'card', 'background', 'field']) {
    assert.match(block, new RegExp(`static let ${name} = T\\.LD\\.`), name)
  }
  const adaptive = read('Sources/Design/Adaptive.swift')
  assert.match(adaptive, /userInterfaceStyle == \.dark \? UIColor\(dark\) : UIColor\(light\)/)
  // Only existing tokens: every pair is built from T.L / T.D / T.S, no new hex values.
  assert.doesNotMatch(adaptive, /hex:/)
})

test('Watch start button uses the on-dark accent (contrast on the black Watch face)', () => {
  const watch = read('Watch/WorkdeckWatchApp.swift')
  assert.match(watch, /\.tint\(recorder\.recording \? T\.S\.failed : T\.S\.arrivedOnDark\)/)
  assert.doesNotMatch(watch, /T\.L\.accent/)
})

test('the type ramp scales with Dynamic Type', () => {
  const typography = read('Sources/Design/Typography.swift')
  const ramp = typography.slice(typography.indexOf('enum F'), typography.indexOf('enum A'))
  for (const name of ['hero', 'display', 'title', 'heading', 'body', 'small', 'micro', 'nano', 'mono']) {
    assert.match(ramp, new RegExp(`static func ${name}\\([^)]*\\)[^{]*\\{\\s*scaled\\(`), name)
  }
  assert.match(ramp, /\.custom\(systemFamily, size: size, relativeTo: style\)/)
})

test('text that carries information is never in the faint (decoration-only) colour', () => {
  for (const f of ['Sources/Features/Firm/FirmInboxView.swift', 'Sources/Features/Firm/FirmSheets.swift']) {
    const lines = read(f).split('\n')
    const bad = lines.map((l, i) => [i + 1, l] as const).filter(([, l]) => /Text\(/.test(l) && /fgFaint/.test(l))
    assert.deepEqual(bad, [], `${f}: use fgMuted for text (fgFaint is about 2.5:1)`)
  }
})

test('filled buttons on the adaptive accent use the on-accent label colour (white on the dark accent is 2.57:1)', () => {
  const files = [
    'Sources/Features/Workspace/WorkspaceView.swift', 'Sources/Features/Firm/FirmMatterView.swift',
    'Sources/Features/Firm/FirmSheets.swift', 'Sources/Features/Queue/QueueView.swift',
    'Sources/Features/Settings/BackupConsentView.swift',
  ]
  for (const f of files) {
    const lines = read(f).split('\n')
    const bad = lines.map((l, i) => [i + 1, l] as const)
      .filter(([, l]) => l.includes('.borderedProminent') && !l.includes('T.LD.onAccent'))
    assert.deepEqual(bad, [], `${f}: add .foregroundStyle(T.LD.onAccent)`)
  }
})

test('only the Personal TabView sets the window colour scheme, and only for Capture (POLISH M42)', () => {
  // preferredColorScheme is window-wide: one inside a tab forced every tab dark.
  const personal = read('Sources/Features/Personal/PersonalWorkspaceView.swift')
  const uses = personal.match(/\.preferredColorScheme\([^)]*\)/g) ?? []
  assert.deepEqual(uses, ['.preferredColorScheme(model.selectedTab == "capture" ? .dark : nil)'])
  const app = read('Sources/App/WorkdeckApp.swift')
  const flow = app.slice(app.indexOf('struct CaptureFlowView'))
  const inFlow = (flow.match(/\.preferredColorScheme\([^)]*\)/g) ?? [])
  // Routes in its full-screen covers are their own presentations and may set it; the flow itself only as a cover.
  const body = flow.slice(0, flow.indexOf('.fullScreenCover')) + flow.slice(flow.indexOf('.toolbar('))
  assert.deepEqual(body.match(/\.preferredColorScheme\([^)]*\)/g) ?? [], ['.preferredColorScheme(onClose == nil ? nil : .dark)'])
  assert.ok(inFlow.length >= 1)
  for (const f of ['Sources/Features/Firm/FirmInboxView.swift', 'Sources/Features/Firm/FirmMatterView.swift', 'Sources/Features/Firm/FirmSheets.swift']) {
    assert.doesNotMatch(read(f), /\.preferredColorScheme\(/, f)
  }
})
