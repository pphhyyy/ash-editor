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
本次不改变笔记、主题、渐隐、标签拖动和图标实现。

## 构建

```sh
xcodebuild -project ASH.xcodeproj -scheme ASH -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Release \
  CODE_SIGNING_ALLOWED=NO build
```

本次未运行新的交互测试。Resources/LiveEditor/editor.html 已打包，
修改前端时先在 LiveEditor/ 安装锁文件依赖再运行 node LiveEditor/build.mjs。
Vendor/ 包含完整 Swift 本地依赖。源码 ZIP 排除 build 和 node_modules。
Recovery/ 为 build 16 恢复时的历史报告，不用于证明本版与 build 16 相同。
