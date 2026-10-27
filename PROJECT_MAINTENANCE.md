# ASH 项目维护与发布规则

这份文档记录 ASH 的版本管理、源码修改、构建、归档和 GitHub 发布流程。后续更新先按这里核对；如果用户对某次更新提出了不同要求，以该次明确要求为准。

## 当前项目基线

- GitHub 仓库：<https://github.com/pphhyyy/ash-editor>
- `main` 保存最新源码；当前更新目标为 ASH 2.0.1，已发布版本使用 `v1.0`、`v2.0` 等标签和独立 Release。
- `source/` 是当前主线的应用源码。版本源信息在 `source/project.yml`，应用的 Info.plist 设置在 `source/Info.plist`。
- 应用产品名和显示名固定为 **ASH**。版本号放在应用版本信息中，不拼进 `.app` 包名；例如 2.0 的产物仍叫 `ASH.app`，可从“关于 ASH”查看 2.0。
- 当前工程目标为 macOS 14 或更新版本，Release 架构配置为 Apple Silicon `arm64`。

## 更新前的项目管理

1. 先看当前分支、提交和工作区状态：

   ```sh
   git status --short --branch
   git log -5 --oneline --decorate
   ```

2. 有未提交修改、历史版本目录或无法确认来源的文件时，先保留现场。需要发布时优先从 GitHub 克隆一份干净副本，或在单独分支工作；不要直接拿混有其他项目文件的目录做发布包。
3. 只修改完成当前需求所需的文件。除非用户明确要求，不删除旧版本源码、历史 app、备份、资源或其他文件，也不改写已发布的 Release。
4. 暂存变更前检查 `git diff` 和 `git status`，只添加本次相关路径。不要在有旧删除项或未确认文件时盲目执行 `git add -A`、`git clean` 或硬重置。
5. 不提交 `.DS_Store`、DerivedData、临时构建产物、用户笔记/图片、密钥、签名证书或访问令牌。发布附件放在 GitHub Release，不把新的 `.app` 或大型构建缓存塞进源码提交。

## 版本和名称

- 用户可见的应用名、产品名和 `.app` 名称始终为 `ASH` / `ASH.app`。不要把 `1.0`、`2.0` 等版本文字加到应用名称或包名。
- 更新版本时，统一核对 `source/project.yml` 的 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`。前者是用户看到的版本，后者是递增的构建号；Info.plist 通过构建设置读取它们。
- 版本号按项目实际发布范围递增，并在开始打包前确定。已发布的版本号和 Release 不回收、不覆盖；修正已发布内容时发布新的版本号。
- Git 标签使用 `v<版本号>`，Release 标题使用 `ASH <版本号>`。当前格式示例：标签 `v2.0`，标题 `ASH 2.0`。
- `main` 指向最新源码。每个 Release 标签必须固定在与该版本相对应的源码提交上，使自动源码快照和附件能追溯到同一版本。

## 修改和构建

1. 先读 `source/README.md`、`source/project.yml` 和相关实现，再改代码。2.0 的图片、加密资源、公式和预览实现都在 `source/`；图片资源库默认位于“文稿/ASH-editor/img”。
2. 前端打包依赖 Node.js 22；源码包含 `LiveEditor/node_modules/`。原生构建需要 Xcode、XcodeGen 和 macOS 14 或更新版本。
3. 在仓库根目录运行以下 Release 构建。派生数据放在 `/tmp`，不要把缓存混进源码：

   ```sh
   cd source/LiveEditor
   node build.mjs
   cd ..
   xcodegen generate
   xcodebuild -project ASH.xcodeproj -scheme ASH -configuration Release \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath /tmp/ASH-DerivedData \
     CODE_SIGNING_ALLOWED=NO build
   ```

   产物位置：`/tmp/ASH-DerivedData/Build/Products/Release/ASH.app`。

4. 打包前核对产物确实来自本次构建，并检查 `CFBundleDisplayName=ASH`、`CFBundleName=ASH`、`CFBundleShortVersionString` 与本次版本一致。不要从旧的 `build/`、下载目录或历史版本目录误取 app。
5. 只记录实际做过的检查。构建成功、包内名称/版本核对、压缩包完整性和签名验证是不同事项，不能互相替代。

## GitHub Release 发布清单

每个版本都单独创建 Release，并上传两个明确命名的附件：

| 内容 | 文件名示例 | 要求 |
| --- | --- | --- |
| 源码 | `ASH-2.0-source.zip` | 对应版本源码；保留构建所需源码与依赖、README 和 `SOURCE-SHA256.txt`，排除 DerivedData 和旧 app |
| macOS app | `ASH-2.0-macOS-arm64.zip` | ZIP 顶层只有 `ASH.app/`；app 内显示名是 ASH，版本号与 Release 一致 |

发布步骤：

1. 确认源码和版本元数据已经提交；核对本次 `git diff`、当前分支和远端地址。
2. 编译 app，检查版本信息，再把正确的 `ASH.app` 复制到临时打包目录。不要重命名成 `ASH-2.0.app`。
3. 单独制作源码 ZIP 和 app ZIP；检查 ZIP 可读取、app ZIP 顶层目录为 `ASH.app`，必要时解压后再次验证签名和版本信息。
4. 提交并推送当前版本源码到 `main`，在对应源码提交上创建 `v<版本号>` 标签并推送标签。
5. 在 GitHub 创建标题为 `ASH <版本号>` 的 Release，上传上述两个 ZIP。发布完成后检查 Release 不是草稿、附件名和大小正确，并确认最新版本标为 Latest。
6. 如果调整 `source/` 文件，重新生成 `source/SOURCE-SHA256.txt` 中对应文件的 SHA-256；校验清单本身不纳入自身哈希。
7. Release 说明写清版本变化、支持的 macOS/架构、下载附件和签名/公证状态；不要声称没有实际验证过的功能或兼容性。

当前发布使用临时签名，未使用 Developer ID 签名或 Apple 公证。若未来要让下载后的 app 不出现首次打开安全提示，需要另行配置有效的 Developer ID 签名和公证流程；不要把临时签名描述成已公证。

## 提交与记录

- 每个提交聚焦一项可描述的更新，提交信息简明写出改动内容；不要把用户数据、构建缓存和 Release 附件混进源码提交。
- 发布完成后，在对应 GitHub Release 写明变化和附件；版本历史以 Git 标签和 Release 为准，不通过删除旧版本目录来“清理”历史。
- 如果构建或发布失败，保留失败现场和已有 Release，先修复后重试；不要为了重试删除已有标签或覆盖已发布版本。
