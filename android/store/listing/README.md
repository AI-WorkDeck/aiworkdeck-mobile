# 商店文案字段映射

来源：`fastlane/metadata/zh-Hans/*.txt`（中文）与
`fastlane/metadata/en-US/*.txt`（英文），按 Android 各商店的字段结构拆分、核对字数上限后落地。
改动顺序照抄 iOS 那份：先改 iOS `fastlane/metadata/`，再回来同步这里——不要在这里单独改词。

## Google Play Console

| 文件 | Play Console 字段 | 上限 | 本文件字数 |
|---|---|---|---|
| `en-US/title.txt` | App name | 30 | 11 |
| `en-US/short_description.txt` | Short description | 80 | 77 |
| `en-US/full_description.txt` | Full description | 4000 | 2147 |
| `en-US/release_notes.txt` | Release notes（当前版本） | 500 | 331 |

`zh-Hans/*` 不直接对应 Play 表单字段（Play 商店页走 `en-US` 一份语言，暂不在 Play Console
额外配置简体中文 listing）；留着是为了给国内六家商店复用同一份文案来源，见下表。

## 国内应用商店（华为 AGC / 应用宝 / 小米 / OPPO / vivo / 荣耀 等）

| 文件 | 国内商店字段 | 上限 | 本文件字数 |
|---|---|---|---|
| `zh-Hans/title.txt` | 应用名称 | 各商店 15-30 不等 | 11 |
| `zh-Hans/short_description.txt` | 一句话简介 / 应用简介 | 各商店 30-80 不等 | 13 |
| `zh-Hans/full_description.txt` | 应用介绍 / 应用描述 | 各商店 700-4000 不等 | 593 |
| `zh-Hans/release_notes.txt` | 更新说明 / 版本更新内容 | 各商店 500 上下 | 92 |

各商店具体字数上限见 `checklist-cn-stores.md`；已标注「待核」的以各商店后台实际表单为准。
