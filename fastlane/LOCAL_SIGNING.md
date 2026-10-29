# 本地 iOS 正式签名

`beta` 和 `release` 仍然会上传 TestFlight；没有新增上传入口。两条本地 lane
共用 `build_local_ipa(build)`，以随机口令创建临时钥匙串，从原位 P12 导入，
配置 codesign ACL，归档与导出后检查 IPA。成功或异常都会移除自己的钥匙串；
不修改旧钥匙串、默认钥匙串或其他任务后来加入的钥匙串。

上传前先按 [iPhone 直板优先的兼容检查流程](../docs/qa/ios-release-compatibility.md)
完成普通 iPhone、Pro Max、Duo 三组原生检查，并审阅实际入口、点击和返回截图。
三个上传 lane 都会先核对当前源码 SHA 的检查结果；本地须保持工作目录干净，
并用已登录的 `gh` 读取 CI。检查缺失、失败或不是当前提交时停止，不读取上传凭据。
普通合并只运行检查；是否上传仍须遵守当次用户发版授权。

按 `EXTERNAL_SERVICES.md` §6.7 提供现有资产路径：

```sh
export DIST_P12_PATH='/原位路径/jwzy-dist.p12'
export DIST_P12_PASSWORD_FILE='/原位路径/p12-password.txt'
```

口令由 helper 直接读原位文件，不写入环境变量或仓库，也不回显 security
命令及其认证错误正文。App、LiveActivity、Watch 三份既有 App Store profiles
需按总表安装；CI 的 `setup_ci`、密码环境输入及 profile 安装方式不变。

ASC 参数仍沿用 `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_PATH`。
本地取号改用 `scripts/asc-next-build.py`，覆盖全 App 的 builds 和 buildUploads。
默认解释器为仓库 `.venv/bin/python`（需 `pyjwt`、`cryptography`），可用
`ASC_PYTHON` 指向已有环境。查询不会原子预留构建号，发布任务仍须串行。

验证：`ruby fastlane/tests/local_signing_test.rb`、`ruby -c fastlane/Fastfile`、
`node contract/tools/check.mjs`。内部 `build_local_ipa(1)` 只打包并验证，不调用
ASC 或上传；build 1 仅用于工具链验证，不能作为最终发布候选。
