// Narrow, expiring exceptions: uncalled html-minifier and uuid v4-only usage.
// These are not package fixes; all other advisories remain blocking.
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { createHash } = require('node:crypto');
const EXPIRES = '2027-02-14T00:00:00Z';
const ALLOWED = new Set(['GHSA-pfq8-rq6v-vf5m', 'GHSA-w5hq-g745-h8pq']);

function validateAudit(report, lock, now = new Date()) {
  if (!report || report.auditReportVersion !== 2 || report.error || !report.vulnerabilities || !report.metadata) throw new Error('Invalid npm audit report');
  const vulnerabilities = report.vulnerabilities;
  if (Object.keys(vulnerabilities).length) {
    for (const [name, version] of Object.entries({ 'html-minifier': '4.0.0', uuid: '3.4.0', 'miniprogram-ci': '2.1.48' })) {
      if (lock.packages[`node_modules/${name}`]?.version !== version) throw new Error(`Exception version changed: ${name}`);
    }
    for (const [location, pkg] of Object.entries(lock.packages)) {
      for (const field of ['dependencies', 'optionalDependencies', 'peerDependencies', 'devDependencies']) {
        for (const name of ['html-minifier', 'uuid']) {
          if (pkg[field]?.[name] && location !== 'node_modules/miniprogram-ci') throw new Error(`New exception consumer: ${location} -> ${name}`);
        }
      }
    }
  }
  if (report.metadata.vulnerabilities?.total !== Object.keys(vulnerabilities).length) throw new Error('Incomplete npm audit report');
  function inspect(name, seen = new Set()) {
    if (seen.has(name)) throw new Error(`Cyclic vulnerability evidence: ${name}`);
    const item = vulnerabilities[name];
    if (!item || !item.via.length || !item.nodes.length) throw new Error(`Unresolved vulnerability: ${name}`);
    const next = new Set(seen).add(name);
    for (const node of item.nodes) {
      if (lock.packages[node]?.dev !== true) throw new Error(`Exception cannot cover runtime dependency: ${node}`);
      if (!['node_modules/html-minifier', 'node_modules/uuid', 'node_modules/miniprogram-ci'].includes(node)) throw new Error(`Unexpected exception location: ${node}`);
    }
    for (const via of item.via) {
      if (typeof via === 'string') inspect(via, next);
      else {
        const id = via.url?.split('/').pop();
        if (!ALLOWED.has(id)) throw new Error(`Unreviewed advisory: ${id || name}`);
        if (now >= new Date(EXPIRES)) throw new Error('Dependency exception expired');
        if ((id === 'GHSA-pfq8-rq6v-vf5m' && name !== 'html-minifier') || (id === 'GHSA-w5hq-g745-h8pq' && name !== 'uuid')) throw new Error(`Unexpected advisory package: ${name}`);
      }
    }
  }
  for (const name of Object.keys(vulnerabilities)) inspect(name);
}

function verifyReachabilityEvidence(root) {
  const sdk = path.dirname(require.resolve('miniprogram-ci/package.json', { paths: [root] }));
  if (JSON.parse(fs.readFileSync(path.join(sdk, 'package.json'))).version !== '2.1.48') throw new Error('SDK exception requires renewed review');
  let uuidImports = 0;
  function scan(directory) {
    for (const item of fs.readdirSync(directory, { withFileTypes: true })) {
      if (item.name === 'node_modules') continue;
      const target = path.join(directory, item.name);
      if (item.isDirectory()) scan(target);
      else if (item.isFile()) {
        const bytes = fs.readFileSync(target);
        if (target.endsWith('package.json') || target.endsWith('.map') || target.endsWith('.d.ts')) continue;
        if (bytes.includes(Buffer.from('html-minifier'))) throw new Error(`Unused minifier exception no longer holds: ${target}`);
        if (target.endsWith('.js')) {
          const source = bytes.toString('utf8');
          for (const match of source.matchAll(/require\(["'](uuid(?:\/[^"']*)?)["']\)/g)) {
            if (match[1] !== 'uuid/v4') throw new Error(`Unsupported UUID API: ${target}`);
            uuidImports++;
          }
        }
      }
    }
  }
  scan(sdk);
  if (uuidImports !== 1) throw new Error('UUID call-site evidence changed');
  const caller = fs.readFileSync(path.join(sdk, 'dist/modules/nativecompiler/ios/buildCloud.js'));
  if (createHash('sha256').update(caller).digest('hex') !== '05a4984b95419f29fcf393b1bf87b9270bd62274a434715d58443cda527f9d5f') throw new Error('UUID call-site fingerprint changed');
}

if (require.main === module) {
  let stdout;
  try { stdout = execFileSync('npm', ['audit', '--json'], { encoding: 'utf8', maxBuffer: 10 * 1024 * 1024 }); }
  catch (error) {
    if (error.status !== 1 || !error.stdout) throw error;
    stdout = error.stdout.toString();
  }
  const report = JSON.parse(stdout);
  validateAudit(report, JSON.parse(fs.readFileSync('package-lock.json', 'utf8')));
  verifyReachabilityEvidence(process.cwd());
  console.log(`Dependency gate passed; only reviewed unused-minifier / UUID-v4 exceptions allowed until ${EXPIRES}`);
}
module.exports = { validateAudit, verifyReachabilityEvidence };
