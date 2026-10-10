<!-- SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->

# 统一项目目录：移动端接续记录（dev-board #1190）

本轮按用户 2026-10-11 指示，将四端项目入口接入账号级云目录。项目名称不能作为身份；资料仍可在桌面或云端存放。免费 200 MB 是同时占用的临时中转空间，订阅 3 GB 是持久云存储，不能拿手机本地预览缓存上限替代云配额。

## 接口与兼容边界

- 四端 `GET /api/mobile/catalog` 消费 `projectUid/name/locations[]`，每个统一项目只占一条。旧 `/mobile/projects` 留给旧客户端。新客户端须在支持 catalog 的后端部署后发布，不单独先发布移动包。
- 每个 location 的 `deviceId/key` 是实际传输地址。默认普通云项目优先，再选在线桌面、离线桌面，最后插件云归档位置。`archiveOnly:true` 不得把本来要送到桌面的采集资料默默改送插件容器。
- 新模型持久保存 `projectUid` 和 location 别名，但既有待传、失败及恢复账本保留原 `deviceId/key`。只通过别名匹配旧记录，不改已经尝试上传的目标。不同统一 ID 永不因同名或数字编号相同而合并。
- iOS 项目文件工作区支持“文件存储位置”切换。云位置读取 `/catalog/{uid}/files` 中 `source=cloud` 的记录，再用 `/catalog/{uid}/files/{fileUid}/content` 获取持久原件；无 PULL、无报价收费、无 ACK 删除。桌面位置继续实时 LIST、明确报价、同 UUID PULL、可靠保存、ACK。
- 文件 `uid` 是跨端身份，`id` 是位置内路由键。旧账本没有 uid 时，仅同一 device/key 与文件 id 可复用 UUID；不得仅因为另一设备的数字文件 id 相同而重用。
- 手机采集仍用 `clientMediaId` 作为幂等键。云目标走原 `/mobile/media` multipart 的 `deviceId=cloud/projectKey=云项目编号`，服务端负责持久归档与收据；四端接受回执的可选 projectUid/fileUid/fileId。本地采集存档仍以 clientMediaId 关联收据，本轮未将文件 uid 回写旧 manifest。
- 四端账户页把现金余额与订阅可用 credits、当前周及当前周期的已用/上限分行展示，不把订阅额度混进充值钱包。iOS/Android/Harmony 原有用量区另显示持久空间；小程序本轮未新建存储用量区。旧响应缺字段不显示新行；持久额度未知显示“暂不可用”，不冒充 0。
- 配额从 `/media/usage` 动态读取。iOS `maximumPreviewBytes=200*1024*1024` 是独立的本机预览缓存限制，本轮没有改成云额度。
- 安卓、鸿蒙的在线提示改为读取 `locations[].online`，不能把长期保留的云目录条目当作在线心跳。

## 本轮验证

在隔离工作树运行，不使用个人账号或真实项目。TypeScript 142 项通过；Android CN Debug 构建与 95 项单测通过；iOS 107 项单测中 105 通过、2 项环境依赖跳过。新增 XCUITest 实际点击云项目、取用文件、预览，再进入混合项目切到云存储查看附件，1 项通过。UI 使用合成服务，不能称为公网跨端联调。

复现命令：

```sh
node contract/tools/check.mjs
npm run typecheck
npm test
JAVA_HOME=$(/usr/libexec/java_home -v 21) \
  ANDROID_HOME=/opt/homebrew/share/android-commandlinetools \
  android/gradlew -p android :app:testCnDebugUnitTest
xcodegen generate --spec ios/project.yml --project ios
# 先按本机实际清单替换 SIMULATOR_ID；不能与其他任务共用正在测试的模拟器。
xcodebuild test -project ios/Workdeck.xcodeproj -scheme Workdeck \
  -only-testing:WorkdeckTests \
  -only-testing:WorkdeckUITests/WorkspaceFlowTests/testCloudOnlyProjectHasWorkingFileEntryAndMixedProjectLocationPicker \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" -parallel-testing-enabled NO
```

验收产物在本机 `/tmp/mobile1190-*`，测试截图由 `mobile1190-derived/Logs/Test` 中 xcresult 导出。它们是临时证据，不是正式包或发布记录。主任务合并前应从服务端最终提交重新运行 `CHECKBA_CLOUD_DIR=... node contract/tools/pull-api.mjs`；工作树脏时钉版会明确标记 dirty，不得冒称可由 commit 复现。

## 未验证与后续交接

没有发布、部署、上传 App Store 包或升级客户端；不要在提交信息加入 `[appstore]`。尚未验证正式 iPhone 的公网录音归档、真实 OSS/订阅额度、Harmony DevEco 原生构建，以及安卓/鸿蒙/小程序的原生 UI。后三端本轮统一的是项目选择与身份，原先没有 iOS 那套项目文件浏览/取回工作区，不能称为四端文件浏览能力完全一致。后续若补后三端文件浏览，复用云/桌面分流契约与幂等账本，不重新设计一套文件 ID。

开发者或 Grok bot 接手时先核对当前 Git、PR、dev-board #1188/#1190 和服务端 OpenAPI 钉版；本记录不代替实际合并与部署状态。

服务端契约已从主任务干净提交 `d99440cf91fb25b70178c26b4cc6006401a1fffc` 重新钉版，sha256 为 `17a7896ef417be71cb5d8e2507035414da21cad24e39bc7e287af8f2f98bd987`。配套主仓 PR：https://github.com/AI-WorkDeck/aiworkdeck/pull/1109；官网 PR：https://github.com/AI-WorkDeck/aiworkdeck_website/pull/237。未部署。
