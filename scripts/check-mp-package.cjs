// SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
// Compile the real upload payload without uploading it. Uses the upload key only
// for the SDK's read-only project configuration lookup.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const ci = require('miniprogram-ci');

async function main() {
  const root = path.resolve(__dirname, '..');
  const project = new ci.Project({
    appid: JSON.parse(fs.readFileSync(path.join(root, 'project.config.json'), 'utf8')).appid,
    type: 'miniProgram',
    projectPath: root,
    privateKeyPath: process.env.MP_UPLOAD_KEY || path.join(os.homedir(), '.aiworkdeck', 'mp-upload-key.pem'),
    ignores: ['node_modules/**/*', 'ios/**/*', 'docs/**/*', 'scripts/**/*', 'fastlane/**/*'],
  });
  const files = await ci.getCompiledResult({
    project,
    setting: { es6: true, enhance: true, minify: true },
    threads: 2,
    onProgressUpdate: () => {},
  }, process.argv[2]);
  const notices = ['MINIMP3-LICENSE', 'LIBFVAD-LICENSE', 'LIBFVAD-PATENTS', 'LIBFVAD-AUTHORS'];
  for (const name of [...notices, 'speech.wasm']) {
    const file = `vendor/speech/${name}${name === 'speech.wasm' ? '' : '.md'}`;
    assert.ok(Object.hasOwn(files, file), `Compiled package is missing ${file}`);
    const original = fs.readFileSync(path.join(root, 'miniprogram/vendor/speech', name));
    assert.deepEqual(Buffer.from(files[file]), original, `Compiled ${file} differs from the original`);
    console.log(`Verified ${file}: ${original.length} bytes, identical to original`);
  }
  console.log(`Mini-program package: ${Object.keys(files).length} files; speech WASM and all four original notices verified`);
}
main().then(() => process.exit(0), error => { console.error(error.message); process.exit(1); });
