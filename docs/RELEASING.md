# 本地打包与 GitHub 发布

当前版本由所有者指定为 **v0.1.0**。`VERSION` 是唯一版本来源，不带 `v` 前缀。日常修改、构建、测试和 commit 不会改变它。只有所有者决定新版本时，才修改 `VERSION` 并添加对应的 `release-notes/v<版本>.md`。

## 发布方式

本项目采用 **本地打包和更新签名 → 手动上传 GitHub Release → 手动发布**。不需要 Apple 开发者会员、发布证书、公证凭据或 GitHub Secrets。GitHub Actions 只执行测试与构建，没有自动发布工作流。

应用使用免费的 ad-hoc 本地代码签名；更新包和 appcast 另外使用 Sparkle Ed25519 密钥签名。前者不提供 Apple 认可的开发者身份，后者用于验证更新确实来自本项目，不能移除。

尚未公证的应用在其他 Mac 上首次打开时可能被系统拦截。确认下载来源后，可在系统设置的“隐私与安全性”中使用“仍要打开”并按系统提示操作。不要关闭 Gatekeeper 或 SIP。更新后 macOS 也可能要求重新授予辅助功能、屏幕录制等权限。以后若需要减少这些提示，可以再引入 Apple Developer ID 与公证。

## 一次性准备

更新地址配置在 `Resources/UpdateConfig.json`，指向 `potatoQi/LumaRing` 最新正式 Release 的 `appcast.xml`。对应公钥已提交；私钥已保存在本机登录钥匙串，账户名为 `local.lumaring.app`。无需导出私钥或上传到 GitHub。

首次由 Sparkle 的 `generate_appcast` 访问私钥时，macOS 可能弹出钥匙串访问提示；允许该工具访问后即可签署更新。签名失败会停止，不会留下可误上传的成品发布目录；处理钥匙串访问问题后重试即可。不要为了重试重新生成密钥，否则已有用户无法验证新的更新。

只读检查公钥：

```bash
swift package --disable-keychain --disable-netrc resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account local.lumaring.app -p
```

私钥应妥善备份；若迁移电脑，可使用 Sparkle 官方导出、导入工具。私钥不能放入仓库、日志、普通配置文件或 Release 附件。

## 本地生成发布文件

```bash
swift test --disable-keychain --disable-netrc
python3 -m unittest discover -s Tests/ReleaseTools -v
bash scripts/prepare-release.sh
```

脚本读取当前版本，构建 Apple Silicon / Intel 双架构应用，签署更新包和更新说明，校验签名与应用包，再生成：

```text
dist/release-v0.1.0/
  LumaRing-0.1.0-macOS.zip
  appcast.xml
  SHA256SUMS
```

ZIP 解压后是 `LumaRing.app`，用户拖入“应用程序”即可安装。更新说明已嵌入带签名的 appcast。

脚本不会 commit、创建标签、push、上传或发布。已有同版本成品目录时会拒绝覆盖；对尚未发布的本地文件，可自行移走旧目录后重试。不要覆盖已经发布版本的资产，修复应由所有者选择新版本。

可用 `LUMARING_PREVIOUS_APPCAST=/路径/appcast.xml bash scripts/prepare-release.sh` 保留此前 feed 的历史条目；脚本先验证旧 feed 签名。改变最低系统要求时，应保留仍兼容旧系统的版本。

## 决定发布时再操作 GitHub

以下步骤只在所有者明确决定发布后执行，本地打包不会触发它们。

1. 提交并推送准备发布的源码，在目标提交上创建与 `VERSION` 完全一致的标签，例如 `v0.1.0`。
2. 在 GitHub 的 Releases 页面新建草稿，选择该标签，填写对应的更新说明。
3. 上传成品目录中的 **全部三个文件**，不要重命名、重压缩或手改签名后的 appcast。
4. 检查版本、说明和附件后，点击 **Publish release**，设为最新正式版本。预发布与草稿不会作为稳定版更新源。

更新客户端从固定的 GitHub HTTPS 地址读取签名 appcast，并验证下载包。仅上传 ZIP 可以供用户手动安装，但不能让自动更新发现新版本；必须同时发布对应的 appcast。

## 用户更新体验与验证

- 应用运行时默认每天检查，提供安装更新、跳过此版本和稍后提醒；手动检查可重新发现被跳过的版本。
- 菜单和设置都有手动检查入口，设置里可关闭自动检查；不会静默安装。
- Sparkle 处理下载、签名验证、安装和重启，不上传窗口、标签页或截图，不开启系统画像统计。
- 旧的本机 1.x 编号是未发布的开发编号，且没有更新模块，需要手动安装一次 v0.1.0。公开用户从 v0.1.0 开始正常升级。

`bash scripts/smoke-update.sh` 用临时测试密钥和真实 Sparkle 工具运行本地发布流程，验证签名、应用包、校验和及防覆盖行为，不访问正式私钥，也不安装或启动测试应用。它不能代替在另一台 Mac 上首次安装和真实旧版到新版的更新实测。
