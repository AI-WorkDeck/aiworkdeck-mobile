// Offline compatibility checks for the pinned mini-program build dependencies.
// No upload, credentials, developer-tools connection, or production traffic.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createRequire } = require('node:module');

async function main() {
  const ci = require('miniprogram-ci');
  const ciRequire = createRequire(require.resolve('miniprogram-ci'));
  const automatorRequire = createRequire(require.resolve('miniprogram-automator'));
  assert.equal(typeof require('miniprogram-automator').connect, 'function');
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aBLsAAAAASUVORK5CYII=', 'base64');
  for (const load of [ciRequire, automatorRequire]) {
    const Jimp = load('jimp');
    const source = new Jimp(2, 3, 0xff0000ff);
    const bytes = await source.getBufferAsync(Jimp.MIME_PNG);
    const image = await Jimp.read(bytes);
    assert.equal(image.bitmap.width, 2);
    assert.equal(image.bitmap.height, 3);
  }
  const sizeOf = ciRequire('image-size').imageSize;
  assert.deepEqual(sizeOf(png), { height: 1, width: 1, type: 'png' });
  const invalidIcns = Buffer.alloc(16);
  invalidIcns.write('icns');
  invalidIcns.writeUInt32BE(16, 4);
  invalidIcns.write('ic07', 8);
  assert.throws(() => sizeOf(invalidIcns));
  const jimpRequire = createRequire(ciRequire.resolve('jimp'));
  const coreRequire = createRequire(jimpRequire.resolve('@jimp/core'));
  const fileType = await import(coreRequire.resolve('file-type'));
  assert.deepEqual(await fileType.fileTypeFromBuffer(png), { ext: 'png', mime: 'image/png' });
  // ASF header with a zero-sized sub-header: formerly an infinite loop.
  const asf = Buffer.alloc(55);
  Buffer.from('3026b2758e66cf11a6d900aa0062ce6c', 'hex').copy(asf);
  asf.writeBigUInt64LE(55n, 16);
  asf.writeUInt32LE(1, 24);
  asf[28] = 1;
  asf[29] = 2;
  await fileType.fileTypeFromBuffer(asf);
  const temp = require('tmp').fileSync({ prefix: '', postfix: '' });
  assert.equal(fs.statSync(temp.name).isFile(), true);
  temp.removeCallback();
  const { XMLBuilder, XMLParser } = require('fast-xml-parser');
  const xml = new XMLBuilder().build({ Result: { Key: 'value&safe' } });
  assert.equal(new XMLParser().parse(xml).Result.Key, 'value&safe');
  const { updateLaunchBase64 } = require('miniprogram-ci/dist/modules/fullcompiler/app/contactandlaunch/updatecontactandlaunch');
  assert.ok(await updateLaunchBase64());
  assert.match(ciRequire('uuid/v4')(), /^[0-9a-f-]{36}$/);
  const request = ciRequire('request');
  const server = require('node:http').createServer((req, res) => {
    if (req.url === '/cross-protocol') {
      res.writeHead(302, { location: `https://127.0.0.1:${server.address().port}/target` });
      res.end();
    } else { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ ok: true })); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    const body = await new Promise((resolve, reject) => request({ url: endpoint, json: true, timeout: 2000 }, (error, response, body) => error ? reject(error) : resolve(body)));
    assert.deepEqual(body, { ok: true });
    const error = await new Promise(resolve => request({ url: `${endpoint}/cross-protocol`, timeout: 2000 }, error => resolve(error)));
    assert.equal(error?.code, 'ERR_INVALID_PROTOCOL');
  } finally { await new Promise(resolve => server.close(resolve)); }
  const projectDir = fs.mkdtempSync(path.join(os.tmpdir(), 'awd-security-compile-'));
  try {
    fs.writeFileSync(path.join(projectDir, 'project.config.json'), JSON.stringify({ appid: 'touristappid', compileType: 'miniprogram', miniprogramRoot: '.', setting: {} }));
    fs.writeFileSync(path.join(projectDir, 'app.json'), JSON.stringify({ pages: [] }));
    const project = new ci.Project({ projectPath: projectDir, type: 'miniProgram', appid: 'touristappid', privateKey: 'synthetic-unused-key' });
    await project.ready();
    const output = await ci.compileJS(project, 'app.js', {
      sourceCode: 'const value = { a: 3 }; module.exports = () => value?.a ?? 0;',
      setting: { es6: true, enhance: true, minify: true },
    });
    assert.equal(typeof output.code, 'string');
    const sandbox = { exports: {} };
    require('node:vm').runInNewContext(output.code, { module: sandbox, require });
    assert.equal(sandbox.exports(), 3);
  } finally {
    fs.rmSync(projectDir, { recursive: true, force: true });
  }
  console.log('security toolchain: Jimp, image headers, tmp, COS XML, SDK protobuf and real offline JavaScript compilation passed');
}
main().then(() => process.exit(0), (error) => { console.error(error); process.exit(1); });
