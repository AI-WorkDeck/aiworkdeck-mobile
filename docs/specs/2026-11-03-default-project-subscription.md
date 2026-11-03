# 临时项目、对话转存与 Apple 月订阅

关联 dev-board #1654、#1655、#1656。

四端的“未选择项目”统一显示“临时项目”。选择时调用经过身份验证的 `POST /api/mobile/catalog/default`，使用服务端返回的唯一默认项目；云端数字 key、跨端 projectUid 和桌面 key 各自保留，不能相互替代。iOS 同一个入口直接打开该项目的文件区，文件区仍可切换正式项目。采集中的项目锁定规则不变。

个人助理可将当前已完成的对话复制到本人正式云项目。候选来自本人 catalog，必须有非 archiveOnly 的 cloud location，排除默认项目及 SCRATCH、LOOSE_FILES。请求使用 cloud location 的数字 key；服务端再次校验所有权。原对话保留，引用的案卷文件不会一起复制，目标项目成员可见副本。此入口已接 iOS、Android、鸿蒙和小程序。

iOS 设置增加 Apple 自动续费月订阅、恢复购买和管理订阅。展示价格以 StoreKit 为准；必须同时满足服务端 capability 开启和 StoreKit 返回匹配的月订阅商品才允许购买。用户点击购买后才 prepare，交易携带服务端 appAccountToken。只接受 StoreKit verified 交易，服务端返回 CONFIRMED 才 finish。失败的交易保留供 updates/unfinished 重放；恢复通过用户触发 AppStore.sync 和 currentEntitlements。充值与订阅按 productId 分流。注销提示说明注销不会取消 Apple 自动续费。

本次不发布客户端或商品，不启用生产购买开关。真实沙盒首购、续费、退款及跨端权益验收仍依赖上架配置与后端上线。

## 导航问题的证据边界

用户设备只读识别为 iPhone DUO / iOS 27.1，安装包 1.9.0 (41)。iPhone 17 Pro / iOS 27.0 模拟器在旋转后，以及 Duo / iOS 27.1 当前窗口中，上传队列关闭、项目返回、采集账户关闭、助理账户关闭均点击通过。Duo 的右侧竖排状态栏与截图一致，不能据此认定坐标错位。尚未复现用户原故障，未做推测性导航修复；新增回归用例保存四入口证据。本次临时项目直接打开详情所需的紧凑布局关闭入口单独补齐。
