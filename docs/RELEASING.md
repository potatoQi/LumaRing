# 版本与发布

## 当前状态

正式版本从 **v0.1.0** 开始。此前的 1.x 是本机开发迭代编号，不是已发布的 GitHub 版本。

`VERSION` 是唯一版本来源，内容不带 `v` 前缀。构建脚本把它写入两个 bundle 版本字段，并用于安装包文件名。普通修改、编译、测试和 commit 都不会自动改版本。仅在项目所有者明确决定发布新版本时修改此文件。

更新源已配置为 `potatoQi/LumaRing` 的最新正式 Release 中的 `appcast.xml`。当前只进行本地提交；仓库、标签和 Release 尚未推送或发布。

## 用户的更新体验

- 默认每天检查一次，应用关闭期间不启动后台服务；再次运行后由 Sparkle 恢复检查。
- 提供“安装更新”“跳过此版本”“稍后提醒”。跳过保存在用户偏好中，下一次新版本仍会提示；手动检查可以重新发现跳过的版本。
- 用户必须选择安装才会下载并安装。自动安装被关闭，设置中可关闭自动检查。
- 菜单和通用设置均有“检查更新…”入口。
- Sparkle 负责安装、重新启动、签名验证以及安装失败的处理。不会改写 LumaRing 的偏好存储。
- 只向 GitHub 请求更新说明和所选安装包；不上传窗口标题、标签页网址或截图，不启用系统画像统计。

旧的本机开发版没有更新模块，且其 1.x 编号高于 0.1.0，因此需要手动安装一次 v0.1.0。公开用户从 v0.1.0 开始走正常升级流程。不要在正式更新源中伪造更高的 build number 来绕过降级规则。

## 首次正式发布前

需要完成两个独立的签名配置：

1. **Apple Developer ID Application 证书与公证**：用于正常分发、稳定的签名身份和系统信任。当前机器未配置该发布证书。开发构建可用于本地测试，但不是已公证的正式安装包；发布脚本会拒绝以 ad-hoc 签名代替正式签名。
2. **Sparkle Ed25519 更新签名**：公钥已保存在 `Resources/UpdateConfig.json`。私钥已由 `generate_keys --account local.lumaring.app` 保存在本机登录钥匙串。不要在升级版本时重新生成密钥，也不要把私钥提交进 Git。

第一次使用签名工具访问钥匙串时，macOS 可能要求允许该工具读取私钥。只读公钥的命令：

```bash
swift package --disable-keychain --disable-netrc resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account local.lumaring.app -p
```

如需备份或配置 CI，使用 Sparkle 官方 `generate_keys --account local.lumaring.app -x <安全位置的私钥文件>` 导出。妥善备份后，把内容配置到 GitHub 的加密 Secret；不要放在项目目录、日志、普通配置文件或 Release 附件中。

在 GitHub 创建名为 `release` 的 Environment，建议设置发布审核人。配置以下 Secrets：

| Secret | 内容 |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Developer ID 证书及私钥的 p12 文件，Base64 编码 |
| `CERTIFICATE_PASSWORD` | p12 导出密码 |
| `LUMARING_SIGN_IDENTITY` | 完整的 `Developer ID Application: …` 身份名称 |
| `APPLE_API_KEY_P8` | Apple 公证 API 私钥内容 |
| `APPLE_API_KEY_ID` | API Key ID |
| `APPLE_API_ISSUER` | API Issuer ID |
| `SPARKLE_PRIVATE_KEY` | 从 LumaRing 钥匙串条目导出的 Sparkle 私钥 |

该工作流只在所有者推送版本标签时触发，不在拉取请求中读取发布 Secrets。依赖版本与 Action revision 均已固定。

## 每次发布

1. **你决定版本**，手动编辑 `VERSION`，例如写入 `0.2.0`，并增加 `release-notes/v0.2.0.md`。新正式版本应高于上一正式版本。
2. 运行本地检查：

```bash
swift test --disable-keychain --disable-netrc
python3 -m unittest discover -s Tests/ReleaseTools -v
bash scripts/build.sh
python3 scripts/check-bundle.py dist/LumaRing.app
bash scripts/smoke-update.sh
```

3. 检查改动后 commit。仅在你决定发布时创建对应的 Git 标签、推送代码和标签。例：

```bash
git tag -a v0.2.0 -m 'LumaRing v0.2.0'
git push origin main
git push origin v0.2.0
```

标签必须与 `VERSION` 完全一致。工作流不会自动升版本、自动提交或替你创建标签。

4. `Prepare Release draft` 会测试、构建双架构包、签名、公证、装订票据、生成并签名 appcast，验证最终归档，然后创建 **草稿**。
5. 查看草稿中的版本、更新说明及附件。确认后点击 GitHub 的 **Publish release**，并将其设为最新正式 Release。草稿和预发布不会通过 `/releases/latest/download/appcast.xml` 推送给稳定版用户。

正式 Release 应包含 `LumaRing-<VERSION>-macOS.zip`、`appcast.xml`、`SHA256SUMS`。不要直接修改签名后的 appcast 或更新包；修改后必须重新签名。不要覆盖已发布版本的资产，应由你选择一个新的版本发布修复。

第一版正式发布后，在一台干净的 Mac 上验证安装及权限；下一版发布前，在隔离测试安装中完整走一遍旧版到新版的安装与重启。

## 本机准备正式资产

已配置 Developer ID 和 Apple 公证钥匙串 profile 时：

```bash
LUMARING_SIGN_IDENTITY='Developer ID Application: 你的身份 (TEAMID)' \
LUMARING_NOTARY_PROFILE='你的公证 profile' \
bash scripts/prepare-release.sh
```

这只在本机生成 `dist/release-v<VERSION>/`，不会 commit、创建 tag 或联系 GitHub。可用 `LUMARING_PREVIOUS_APPCAST` 指向先前已验证的 feed，以保留历史条目；改变最低系统要求时尤其需要保留兼容旧系统的版本。

## 开发构建和验证边界

`bash scripts/build.sh` 默认生成本地开发构建，并保留 framework 的完整结构和权限。正式构建必须设置 `LUMARING_BUILD_MODE=distribution`，使用 Developer ID 和 Hardened Runtime。开发构建不作为正式发布产物。

`smoke-update.sh` 使用临时、确定性的测试密钥，调用真实 Sparkle `generate_appcast`，再用公钥验证安装包和更新说明的签名。它不读取正式私钥，不启动或安装测试应用，退出时删除临时文件。该测试不能代替 Developer ID、公证或真实用户的完整升级测试。
