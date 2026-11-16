import { test } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

test('patched mini-program toolchain preserves offline compiler and image APIs', () => {
  // A parser regression must fail in a bounded subprocess, not hang the test runner.
  const output = execFileSync(process.execPath, [fileURLToPath(new URL('../scripts/verify-security-toolchain.cjs', import.meta.url))], {
    timeout: 60_000,
    encoding: 'utf8',
  })
  assert.match(output, /real offline JavaScript compilation passed/)
})

import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { validateAudit } = require('../scripts/check-security-dependencies.cjs')

function reviewedReport() {
  return {
    auditReportVersion: 2,
    metadata: { vulnerabilities: { total: 1 } },
    vulnerabilities: {
      uuid: { nodes: ['node_modules/uuid'], via: [{ url: 'https://github.com/advisories/GHSA-w5hq-g745-h8pq' }] },
    },
  }
}
const reviewedLock = { packages: {
  'node_modules/uuid': { dev: true, version: '3.4.0' },
  'node_modules/html-minifier': { dev: true, version: '4.0.0' },
  'node_modules/miniprogram-ci': { dev: true, version: '2.1.48', dependencies: { uuid: '^3.1.0', 'html-minifier': '4.0.0' } },
} }
const reviewDate = new Date('2026-11-16T00:00:00Z')
test('dependency exception is limited to reviewed advisories, development nodes and expiry', () => {
  validateAudit(reviewedReport(), reviewedLock, reviewDate)
  const newAdvisory = reviewedReport()
  newAdvisory.vulnerabilities.uuid.via.push({ url: 'https://github.com/advisories/GHSA-unreviewed' })
  assert.throws(() => validateAudit(newAdvisory, reviewedLock, reviewDate), /Unreviewed advisory/)
  assert.throws(() => validateAudit(reviewedReport(), { packages: { ...reviewedLock.packages, 'node_modules/uuid': { dev: false, version: '3.4.0' } } }, reviewDate), /runtime dependency/)
  assert.throws(() => validateAudit(reviewedReport(), reviewedLock, new Date('2027-02-14T00:00:00Z')), /expired/)
  const moved = reviewedReport()
  moved.vulnerabilities.uuid.nodes = ['node_modules/another-package/node_modules/uuid']
  assert.throws(() => validateAudit(moved, { packages: { ...reviewedLock.packages, [moved.vulnerabilities.uuid.nodes[0]]: { dev: true } } }, reviewDate), /Unexpected exception location/)
  assert.throws(() => validateAudit(reviewedReport(), { packages: { ...reviewedLock.packages, 'node_modules/new-consumer': { dependencies: { uuid: '^3.0.0' } } } }, reviewDate), /New exception consumer/)
  assert.throws(() => validateAudit(reviewedReport(), { packages: { ...reviewedLock.packages, 'node_modules/uuid': { dev: true, version: '3.3.3' } } }, reviewDate), /Exception version changed/)
  assert.throws(() => validateAudit({ error: 'registry unavailable' }, reviewedLock, reviewDate), /Invalid npm audit report/)
})
