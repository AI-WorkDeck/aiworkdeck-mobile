#!/usr/bin/env node
// 商店文案字数核对：按各文件对应商店字段的上限报表，超限退出码非零。
// 见 docs/specs/2026-09-13-store-assets-design.md §5、任务书「任务 A 6」。
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = path.resolve(fileURLToPath(import.meta.url), "../../..");

function chars(s) {
  // 按 Unicode 码点计数（与 Apple/多数商店表单的「字符数」一致），排除结尾换行。
  return Array.from(s.replace(/\n$/, "")).length;
}

function bytes(s) {
  return Buffer.byteLength(s.replace(/\n$/, ""), "utf8");
}

const rows = [
  // --- App Store (fastlane/metadata) ---
  { file: "fastlane/metadata/zh-Hans/subtitle.txt", label: "App Store 副标题 zh-Hans", limit: 30, unit: chars },
  { file: "fastlane/metadata/en-US/subtitle.txt", label: "App Store 副标题 en-US", limit: 30, unit: chars },
  { file: "fastlane/metadata/zh-Hans/promotional_text.txt", label: "App Store 推广文本 zh-Hans", limit: 170, unit: chars },
  { file: "fastlane/metadata/en-US/promotional_text.txt", label: "App Store 推广文本 en-US", limit: 170, unit: chars },
  { file: "fastlane/metadata/zh-Hans/keywords.txt", label: "App Store 关键词 zh-Hans", limit: 100, unit: bytes },
  { file: "fastlane/metadata/en-US/keywords.txt", label: "App Store 关键词 en-US", limit: 100, unit: bytes },
  { file: "fastlane/metadata/zh-Hans/description.txt", label: "App Store 描述 zh-Hans", limit: 4000, unit: chars },
  { file: "fastlane/metadata/en-US/description.txt", label: "App Store 描述 en-US", limit: 4000, unit: chars },
  { file: "fastlane/metadata/zh-Hans/release_notes.txt", label: "App Store 更新说明 zh-Hans", limit: 4000, unit: chars },
  { file: "fastlane/metadata/en-US/release_notes.txt", label: "App Store 更新说明 en-US", limit: 4000, unit: chars },

  { file: "fastlane/metadata/zh-Hant/subtitle.txt", label: "App Store 副標題 zh-Hant", limit: 30, unit: chars },
  { file: "fastlane/metadata/zh-Hant/promotional_text.txt", label: "App Store 推廣文字 zh-Hant", limit: 170, unit: chars },
  { file: "fastlane/metadata/zh-Hant/keywords.txt", label: "App Store 關鍵字 zh-Hant", limit: 100, unit: bytes },
  { file: "fastlane/metadata/zh-Hant/description.txt", label: "App Store 描述 zh-Hant", limit: 4000, unit: chars },
  { file: "fastlane/metadata/zh-Hant/release_notes.txt", label: "App Store 更新說明 zh-Hant", limit: 4000, unit: chars },
  { file: "android/store/listing/zh-Hant/title.txt", label: "Play App name zh-Hant", limit: 30, unit: chars },
  { file: "android/store/listing/zh-Hant/short_description.txt", label: "Play Short description zh-Hant", limit: 80, unit: chars },
  { file: "android/store/listing/zh-Hant/full_description.txt", label: "Play Full description zh-Hant", limit: 4000, unit: chars },
  { file: "android/store/listing/zh-Hant/release_notes.txt", label: "Play Release notes zh-Hant", limit: 500, unit: chars },

  // --- Google Play（android/store/listing/en-US，见该目录 README）---
  { file: "android/store/listing/en-US/title.txt", label: "Play App name", limit: 30, unit: chars },
  { file: "android/store/listing/en-US/short_description.txt", label: "Play Short description", limit: 80, unit: chars },
  { file: "android/store/listing/en-US/full_description.txt", label: "Play Full description", limit: 4000, unit: chars },
  { file: "android/store/listing/en-US/release_notes.txt", label: "Play Release notes", limit: 500, unit: chars },

  // --- 国内安卓商店（android/store/listing/zh-Hans，取各商店区间里更严格的下限）---
  { file: "android/store/listing/zh-Hans/title.txt", label: "国内商店 应用名称 zh-Hans", limit: 15, unit: chars },
  { file: "android/store/listing/zh-Hans/short_description.txt", label: "国内商店 一句话简介 zh-Hans", limit: 30, unit: chars },
  { file: "android/store/listing/zh-Hans/full_description.txt", label: "国内商店 应用介绍 zh-Hans", limit: 700, unit: chars },
  { file: "android/store/listing/zh-Hans/release_notes.txt", label: "国内商店 更新说明 zh-Hans", limit: 500, unit: chars },

  // --- 华为 AGC（harmony/store/listing/zh-Hans，字段上限待核，见该目录 README）---
  { file: "harmony/store/listing/zh-Hans/name.txt", label: "AGC 应用名称（待核）", limit: 15, unit: chars },
  { file: "harmony/store/listing/zh-Hans/short_description.txt", label: "AGC 应用简介（待核，取第三方最严格说法）", limit: 15, unit: chars },
  { file: "harmony/store/listing/zh-Hans/full_description.txt", label: "AGC 应用介绍（待核）", limit: 8000, unit: chars },
  { file: "harmony/store/listing/zh-Hans/release_notes.txt", label: "AGC 更新说明（待核）", limit: 1000, unit: chars },

  // --- 微信小程序简介（docs/store/miniprogram-intro.md 里的代码块，待核）---
  { file: "docs/store/miniprogram-intro.md", label: "小程序简介（待核）", limit: 120, unit: chars, extract: extractFencedBlock },
];

function extractFencedBlock(text) {
  const m = text.match(/```\n([\s\S]*?)\n```/);
  if (!m) throw new Error("未找到 ``` 代码块");
  return m[1];
}

let failed = false;
const lines = [];
lines.push(
  ["文件", "字段", "上限", "实际", "单位", "结果"].join(" | ")
);
lines.push(["---", "---", "---", "---", "---", "---"].join(" | "));

for (const row of rows) {
  const abs = path.join(root, row.file);
  if (!existsSync(abs)) {
    failed = true;
    lines.push(`${row.file} | ${row.label} | ${row.limit} | (缺文件) | - | FAIL`);
    continue;
  }
  let text = readFileSync(abs, "utf8");
  if (row.extract) text = row.extract(text);
  const count = row.unit(text);
  const unitLabel = row.unit === bytes ? "字节" : "字符";
  const ok = count <= row.limit;
  if (!ok) failed = true;
  lines.push(
    `${row.file} | ${row.label} | ${row.limit} | ${count} | ${unitLabel} | ${ok ? "OK" : "FAIL"}`
  );
}

console.log(lines.join("\n"));

if (failed) {
  console.error("\n有字段超限，见上表 FAIL 行。");
  process.exit(1);
} else {
  console.log("\n全部字段在上限内。");
}
