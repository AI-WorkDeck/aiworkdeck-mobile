// Adapt legacy SDK call sites to maintained parser APIs. Refuse upstream
// drift: these patches must be reviewed again when either caller changes.
const fs = require('node:fs');
const { createRequire } = require('node:module');
const { createHash } = require('node:crypto');
const path = require('node:path');
const ciRequire = createRequire(require.resolve('miniprogram-ci'));
const jimpRequire = createRequire(ciRequire.resolve('jimp'));
const coreRequire = createRequire(jimpRequire.resolve('@jimp/core'));
const automatorRequire = createRequire(require.resolve('miniprogram-automator'));
const automatorJimpRequire = createRequire(automatorRequire.resolve('jimp'));
const automatorCoreRequire = createRequire(automatorJimpRequire.resolve('@jimp/core'));
const patches = [
  {
    file: path.join(path.dirname(coreRequire.resolve('@jimp/core')), 'utils/image-bitmap.js'),
    originalHash: '172dde837487d4c55ba00c82089f4ee91bf6fa9209072b9b368e954b95a21512',
    from: '_interopRequireDefault(require("file-type"))',
    to: '{ default: { fromBuffer: (buffer) => import("file-type").then(({ fileTypeFromBuffer }) => fileTypeFromBuffer(buffer)) } }',
  },
  {
    file: require.resolve('miniprogram-ci/dist/modules/nativecompiler/ios/buildCloud'),
    originalHash: '2f6a16bb69f0b09383a6d94f317c323644eb72290d91c16e6586cd16b172a26e',
    from: 'sizeOf=require("image-size")',
    to: 'sizeOf=(input)=>require("image-size").imageSize(typeof input==="string"?require("node:fs").readFileSync(input):input)',
  },
  {
    file: path.join(path.dirname(coreRequire.resolve('@jimp/core')), 'request.js'),
    originalHash: 'cfea62f32901cbaf9e81f27f17735e0c557e6222e1d9a7f61440efd57b5c20e7',
    from: "require(\"phin\")",
    to: "require(\"phin\").unpromisified",
  },
  {
    file: path.join(path.dirname(automatorCoreRequire.resolve('@jimp/core')), 'request.js'),
    originalHash: '1dd841cf3ceb0489519a57129f94ca01dcb1c4a7f7bce1770a95928afa461520',
    from: "require('phin')",
    to: "require('phin').unpromisified",
  },
];
const replacements = patches.map(({ file, originalHash, from, to }) => {
  const current = fs.readFileSync(file, 'utf8');
  const original = current.includes(to) ? current.replace(to, from) : current;
  if (createHash('sha256').update(original).digest('hex') !== originalHash || original.split(from).length !== 2) {
    throw new Error(`Security compatibility patch requires review: ${file}`);
  }
  return [file, original.replace(from, to)];
});
for (const [file, source] of replacements) fs.writeFileSync(file, source);
console.log('Applied verified mini-program parser compatibility patches');
