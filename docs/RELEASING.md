# 本地打包与 GitHub 发布

当前版本由所有者指定为 **v0.1.0**。`VERSION` 是唯一版本来源，不带 `v` 前缀。日常修改、构建、测试和 commit 不会改变它。只有所有者决定新版本时，才修改 `VERSION` 并添加对应的 `release-notes/v<版本>.md`。

## 发布方式

本项目采用 **本地打包和更新签名 → 手动上传 GitHub Release → 手动发布**。使用固定的自签名证书，不需要 Apple 开发者会员、Apple 发布证书、公证凭据或 GitHub Secrets。GitHub Actions 只执行测试与构建，没有自动发布工作流。

首次安装使用 **DMG**，打开后将 LumaRing 拖到旁边的 Applications。**ZIP** 专供 Sparkle 更新使用。两者包含同一次构建的应用，DMG 不会绕过 macOS 签名和授权检查。

应用使用免费的固定自签名身份 `LumaRing Local Signing`；`Resources/SigningIdentity.json` 只记录公开的证书名称和 SHA-1 指纹，用来准确选择钥匙串中的身份。正常构建找不到该身份时会停止，绝不自动回退到 ad-hoc。证书和对应私钥应长期保留，后续构建使用同一身份及 Bundle ID，避免临时签名每次改变身份而使旧权限失效。

自签名不提供 Apple 认可的开发者身份。更新包和 appcast 另外使用 Sparkle Ed25519 密钥签名，用于验证更新确实来自本项目，不能移除；两套签名不能互相替代。

尚未公证的应用在其他 Mac 上首次打开时可能被系统拦截。确认下载来源后，可在系统设置的“隐私与安全性”中使用“仍要打开”并按系统提示操作。用户不需要创建或导入签名证书；首次使用仍需授予辅助功能和录屏权限。不要关闭 Gatekeeper 或 SIP。从旧 ad-hoc 版本迁移，或更换签名身份时，可能需要移除旧授权、重新授权并重启应用。固定签名不能免除 macOS 自身要求的后续确认。以后若需要改善首次安装体验，可以再引入 Apple Developer ID 与公证。

## 一次性准备

### 应用代码签名

发布者的固定证书及私钥保存在登录钥匙串中。当前证书通过“钥匙串访问 → 证书助理 → 创建证书”生成，名称为 `LumaRing Local Signing`，类型为“代码签名”，4096 位 RSA，仅启用数字签名和代码签名用途，不具有签发其他证书的能力。证书有效期至 2036-09-04；本机只为此证书设置代码签名用途的信任。

只读检查：

```bash
security find-identity -v -p codesigning
python3 scripts/sign_bundle.py --check
```

迁移电脑时，通过钥匙串访问导出带密码保护的证书和私钥备份，并导入新电脑。备份应离线妥善保存；不要将私钥、导出文件或密码写入仓库、日志或 Release。丢失私钥后重新创建同名证书不能恢复原签名身份。构建脚本不会创建证书或修改信任设置。

贡献者可用自己的固定身份构建，例如 `LUMARING_SIGN_IDENTITY="自己的证书指纹或完整名称" bash scripts/build.sh`。只有可丢弃的测试构建才显式使用 `LUMARING_SIGN_IDENTITY=- bash scripts/build.sh`；CI 使用这一模式，不持有正式私钥，产物不用于发布。以 `Developer ID Application:` 开头的身份仍支持 Hardened Runtime 和时间戳，但公证需要单独配置。

本机已验证同证书替换安装：两份内容哈希不同的应用包拥有相同的指定要求（Bundle ID + 证书指纹）；首次授权后，替换为最终构建无需再次授权，应用内辅助功能检查及真实录屏访问均成功。测试不修改版本号，最终安装包不含测试标记。这不等同于在其他 macOS 版本上的验证，也不代替首次安装及 Sparkle 跨版本更新实测。

### Sparkle 更新签名

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
  LumaRing-0.1.0-macOS.dmg
  LumaRing-0.1.0-macOS.zip
  appcast.xml
  SHA256SUMS
```

DMG 是对用户提供的主要下载，ZIP 是 appcast 中的更新包。生成 appcast 时只传入 ZIP，完成后再加入 DMG，避免同版本两个安装包竞争更新条目。SHA256SUMS 包含 DMG、ZIP 和 appcast 的校验和；更新说明已嵌入带签名的 appcast。

仅生成本地安装包可运行 `bash scripts/build.sh`，产物位于 `dist/`。构建会只读挂载 DMG，检查 Applications 链接、应用签名及完整文件与符号链接的一致性，随后卸载；不启动或安装应用。

脚本不会 commit、创建标签、push、上传或发布。已有同版本成品目录时会拒绝覆盖；对尚未发布的本地文件，可自行移走旧目录后重试。不要覆盖已经发布版本的资产，修复应由所有者选择新版本。

可用 `LUMARING_PREVIOUS_APPCAST=/路径/appcast.xml bash scripts/prepare-release.sh` 保留此前 feed 的历史条目；脚本先验证旧 feed 签名。改变最低系统要求时，应保留仍兼容旧系统的版本。

## 决定发布时再操作 GitHub

以下步骤只在所有者明确决定发布后执行，本地打包不会触发它们。

1. 提交并推送准备发布的源码，在目标提交上创建与 `VERSION` 完全一致的标签，例如 `v0.1.0`。
2. 在 GitHub 的 Releases 页面新建草稿，选择该标签，填写对应的更新说明。
3. 上传成品目录中的 **全部四个文件**，不要重命名、重压缩或手改签名后的 appcast。下载说明优先链接 DMG。
4. 检查版本、说明和附件后，点击 **Publish release**，设为最新正式版本。预发布与草稿不会作为稳定版更新源。

更新客户端从固定的 GitHub HTTPS 地址读取签名 appcast，并验证 ZIP 更新包。仅上传 DMG 可供用户手动安装；自动更新必须同时提供 ZIP 和对应的 appcast。

## 用户更新体验与验证

- 应用运行时默认每天检查，提供安装更新、跳过此版本和稍后提醒；手动检查可重新发现被跳过的版本。
- 菜单和设置都有手动检查入口，设置里可关闭自动检查；不会静默安装。
- Sparkle 处理下载、签名验证、安装和重启，不上传窗口、标签页或截图，不开启系统画像统计。
- 旧的本机 1.x 编号是未发布的开发编号，且没有更新模块，需要手动安装一次 v0.1.0。公开用户从 v0.1.0 开始正常升级。

`bash scripts/smoke-update.sh` 用临时测试密钥和真实 Sparkle 工具运行本地发布流程，验证 DMG 与 ZIP 内应用一致、更新 feed 仍指向 ZIP、签名、校验和及防覆盖行为，不访问正式私钥，也不安装或启动测试应用。它不能代替在另一台 Mac 上首次安装和真实旧版到新版的更新实测。
