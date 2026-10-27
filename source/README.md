# ASH 2.0.2

本目录基于 ASH 1.0 / build18 源码。2.0 加入图片与公式功能；2.0.1 修复切换公式定界符后的预览更新；2.0.2 修复反斜杠显示公式的块级解析，原 1.0 Release 保持不变。

## 2.0 图片与公式

- 实时编辑和阅读预览由离线 Milkdown / KaTeX 完成。偏好设置可选 `$…$` / `$$…$$`，或 `\(…\)` / `\[…\]`；切换时会统一当前文档中的公式标记，并立即重新解析预览。`\[…\]` 显示公式会转换为独立公式块，并与相邻段落隔开后交给解析器。
- 聊天框模式使用原生文本编辑器，不启用数学公式渲染。
- 块级公式默认显示渲染结果；需要修改时，可从公式块工具栏切换到 LaTeX 源码编辑，再切回预览。
- 在编辑器中粘贴 PNG 或 JPEG，会先放入系统“文稿”中的 `ASH-editor/img`，编辑期间保持普通图片格式。首次使用时需在系统文件选择框中授权“文稿”文件夹；之后 ASH 通过安全书签访问统一资源库。保存文档时，所有可访问的本地 PNG/JPEG 图片都会迁移到该目录并以 AES-GCM 加密：JPEG 使用 `.ashj`，PNG 使用 `.ashp`。文档中保存稳定的 `ash-asset://` 引用，因此切换当前工作文件夹或移动 `.ash` 文档后仍能找到图片。资源使用与 ASH 文档相同的密码或本机钥匙串密钥，并沿用 ASH 的 PBKDF2-SHA256 密钥派生参数；编辑器预览时只在内存中解密。
- 文档写入成功后会移除粘贴时的明文暂存文件。解密失败或文档写入失败时不会删除原暂存图。
- 图片默认居中显示，右键可切换为左对齐；拖拽右下角手柄调整大小时保持当前对齐。尺寸和对齐方式随 Markdown 保存，重新打开后恢复，原始加密图片不做缩放重编码。
- KaTeX 字体已内嵌到本地编辑器资源，不依赖 CDN 或网络。

## 构建

需要 macOS 14 或更新版本、Xcode、XcodeGen，以及 Node.js 22。本实验目录的锁文件依赖已放在 `LiveEditor/node_modules/`；在 `LiveEditor/` 中用工作区自带的 Node 运行打包脚本，再回到本目录运行 Xcode 构建：

```sh
cd LiveEditor
node build.mjs
cd ..
xcodegen generate
xcodebuild -project ASH.xcodeproj -scheme ASH -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath ../build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

构建产物为 `../build/DerivedData/Build/Products/Release/ASH.app`，应用显示名称为 `ASH`，版本号为 2.0.2，可从应用菜单“关于 ASH”查看。

---

以下是 build18 / 1.0 基线说明，作为本实验副本的来源记录。

---

# ASH 1.0（build18 代码基线）

应用版本统一为 1.0（build 1）。源码以 build18 为代码基线，包含 Dock 退出崩溃修复；原有 build 16、17、18 文件均保留不动。 本次修复渐隐动画在连续输入时被反复重启的问题：每段新文字使用稳定的 CSS 动画参数，动画按实际时间连续推进。

## 原因与修复

build 16 的报告缺失 windowDidBecomeKey: 接收方法；
build 17 的报告缺失系统内部 windowWillOrderOnScreen: 接收方法。
两次都在 ApplicationQuitGuard.prepareToQuit 将窗口带到前台时由通知中心触发。

根因是 UnsavedCloseInterceptor 覆盖 responds(to:) 和 forwardingTarget(for:)，
根据 weak previousDelegate 声称支持其他对象的方法。
AppKit 会缓存通知接收能力，原代理稍后不存在时转发失败。
build 17 只补齐公开通知仍然不完整。

build 18 删除这两个动态转发重写。通知中心只会登记本对象真正实现的方法。
显式保留 29 个公开窗口通知和关闭、编辑器、缩放、尺寸、撤销管理接口的安全转发。
标签栏由一个原生 AppKit `NSControl` 统一处理命中、点击和拖放：仅空白区域调用 `NSWindow.performDrag`；标签通过 `NSDraggingSession` 拖放，不与窗口拖动手势叠加。标签与侧栏文件使用各自的 ASH 专用拖放数据类型，避免正文编辑器将其识别为文本。标签可在同栏重排，也可拖入另一分栏的标签栏或正文区；侧栏中的 ASH / Markdown 文件可拖到目标分栏打开。拖入已在另一栏打开的文件时，会移动现有标签。

## 构建

主窗口忽略隐藏标题栏造成的顶部安全区，让文档标题和操作按钮上移；侧栏标题增加顶部留白。纯净模式下，标签栏空白处拖动窗口，标签页和按钮保留各自交互。标签使用系统拖放事件处理同栏重排和跨栏移动，正文区也接收标签拖放；侧栏文件可拖入指定分栏。标签栏右移避开窗口控制按钮，紫色竖线标出插入位置。聊天框拖动条缩窄并使用当前文字色的轻微色差，适配紫雾、纸感、夜色三种主题。

```sh
xcodebuild -project ASH.xcodeproj -scheme ASH -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Release \
  CODE_SIGNING_ALLOWED=NO build
```

Resources/LiveEditor/editor.html 已打包，
修改前端时先在 LiveEditor/ 安装锁文件依赖再运行 node LiveEditor/build.mjs。
Vendor/ 包含完整 Swift 本地依赖。源码 ZIP 排除 build 和 node_modules。
Recovery/ 为 build 16 恢复时的历史报告，不用于证明本版与 build 16 相同。

## 标题栏事件冲突的补充修复

此前 `NSView.mouseDownCanMoveWindow = false` 只处理视图事件，未阻止系统在全尺寸标题栏区域预先启动拖窗。本机 macOS 26.3.1 的运行检查显示：旧标签栏的系统拖窗排除矩形为零，`NSControl` 的排除矩形覆盖整个控件。因此标签栏改为继承 `NSControl`，由 AppKit 自身排除默认标题栏拖动，再仅在空白处显式调用 `performDrag`。没有增加标题栏高度，也没有在产品代码中调用私有 API。

参考：[Chromium 对标题栏系统拖动机制的修复说明](https://chromium.googlesource.com/chromium/src.git/+/8d3f27fbbbaa20f142e32b96d2936782e168e3aa)。排除区域的实际结果已在本机进行对照检查；真实鼠标拖动仍待确认。

## 本次拖放验证

已通过原生事件检查：标签选择、关闭、新建与空白处拖窗分别进入对应处理；左右、上下分栏的原生标签栏均接收跨栏拖放，左右插入位置一致，计算时排除正在拖动的标签。已通过透明标题栏的实际 AppKit 视图命中检查。Release 编译通过。桌面操作工具启动失败，尚未完成真实鼠标操作的端到端确认。

纯净模式在标签上方预留 10pt 空白拖窗区，标签本身保持 32pt 高；空白区与标签、新建按钮的命中范围分开，沿用 NSControl 的系统标题栏排除处理。

输入法候选框出现时，原生编辑器仅避开当前组词的 marked range，其他文字继续按各自的时间渐隐；不修改组词属性和选区。普通输入与聊天框模式共用此修复。

## 多步撤销与重做

原生正文与聊天框使用每个编辑器独立的 AppKit UndoManager，保留 500 组系统编辑操作。连续输入停顿达到 0.5 秒时，通过 NSTextView.breakUndoCoalescing 分成下一步；换行、粘贴、批量替换也分开，不拆开正在进行的输入法组词。实时预览沿用 Milkdown / ProseMirror 的事务历史插件，depth 为 500、newGroupDelay 为 500ms。代码块沿用 CodeMirror 自带撤销机制。

使用 ⌘Z 逐步撤销，⇧⌘Z 逐步重做。历史属于当前编辑器实例，不写进 Markdown / ASH 文件，也不跨编辑器重建或重启保存。

参考：[AppKit breakUndoCoalescing](https://developer.apple.com/documentation/appkit/nstextview/breakundocoalescing())、[ProseMirror History](https://prosemirror.net/docs/ref/#history)。本次已完成前端打包与 Release 编译，尚未进行真实键盘操作验证。

侧栏“当前文件夹”标题提供 × 关闭按钮，清空文件树并移除自动恢复的文件夹书签；不删除磁盘文件，也不关闭已打开的文档标签。

## 标题与文件名同步

打开文档时，标题统一使用不含扩展名的文件名。编辑标题后，⌘S 在原文件夹中重命名，保留原扩展名、文件格式和加密方式；另存为后标题与选择的文件名一致。使用 NSFileCoordinator 的移动通知维护系统文件访问授权，成功后更新最近文档与文件树。目标已有其他同名文件时拒绝自动覆盖；无效标题会提示修改。若写入成功但重命名失败，内容仍保存在原路径并显示错误。

文件夹 × 按钮关闭文件树并移除文件夹恢复书签；已打开文档通过自身书签继续获取文件访问权限。

## Markdown 配色与 Obsidian 高亮

紫雾、纸感、夜色分别定义行内代码、代码块、链接、列表、引用、表格、选区和折叠块的配色，避免夜色沿用浅色背景。编辑和只读预览共用离线 Milkdown 渲染器；普通源码输入模式仍显示原始 Markdown。

支持 Obsidian 官方的六色语法：`==文字==` 默认为黄色，`==🔴文字==`、`==🟠文字==`、`==🟡文字==`、`==🟢文字==`、`==🔵文字==`、`==🟣文字==` 对应六种底色。颜色前缀在渲染时隐藏，保存时保留；支持嵌套加粗、斜体、表格和折叠内容。行内代码、代码块及转义标记保持字面文本。分隔符解析器改编自 micromark 的 GFM strikethrough，实现和 MIT 许可在 LiveEditor/highlight-syntax.js；采用 Markdown AST / ProseMirror mark 进行往返转换，不改写为 HTML 存盘。

参考：[Obsidian 官方语法](https://obsidian.md/help/syntax)。

验证：WebKit 下三种默认主题各 25 类文字元素对比度均不低于 4.5:1；高亮颜色保存、重新打开、输入规则、嵌套格式、转义、代码字面值及只读代码块保护检查通过。原有 editor.test.mjs 检查通过。LiveEditor/theme.test.mjs 可重复检查并导出截图与对比度报告（`node LiveEditor/theme.test.mjs`，需要已安装的本地 Playwright WebKit）。
