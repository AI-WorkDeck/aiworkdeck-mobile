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
const reviewedLock = { packages: { 'node_modules/uuid': { dev: true } } }
const reviewDate = new Date('2026-11-16T00:00:00Z')
test('dependency exception is limited to reviewed advisories, development nodes and expiry', () => {
  validateAudit(reviewedReport(), reviewedLock, reviewDate)
  const newAdvisory = reviewedReport()
  newAdvisory.vulnerabilities.uuid.via.push({ url: 'https://github.com/advisories/GHSA-unreviewed' })
  assert.throws(() => validateAudit(newAdvisory, reviewedLock, reviewDate), /Unreviewed advisory/)
  assert.throws(() => validateAudit(reviewedReport(), { packages: { 'node_modules/uuid': { dev: false } } }, reviewDate), /runtime dependency/)
  assert.throws(() => validateAudit(reviewedReport(), reviewedLock, new Date('2027-02-14T00:00:00Z')), /expired/)
  const moved = reviewedReport()
  moved.vulnerabilities.uuid.nodes = ['node_modules/another-package/node_modules/uuid']
  assert.throws(() => validateAudit(moved, { packages: { [moved.vulnerabilities.uuid.nodes[0]]: { dev: true } } }, reviewDate), /Unexpected exception location/)
  assert.throws(() => validateAudit({ error: 'registry unavailable' }, reviewedLock, reviewDate), /Invalid npm audit report/)
})
