# ASH 2.0.3

- 可运行 app：`ASH.app`（显示名称为 ASH；版本 2.0.3 可从“关于 ASH”查看）
- 完整源码和离线依赖：`source/`

编译需要 macOS 14 或更新版本、Xcode、XcodeGen 和 Node.js 22。Node.js 可从系统 `PATH` 中调用；源码压缩包自带前端依赖，不依赖本目录之外的工具或文件。

2.0.3 修复粘贴带 `\(...\)` / `\[...\]` 的 Markdown 后公式不渲染的问题；聊天框模式继续使用普通文本输入。

构建方法和具体实现记录见 [`source/README.md`](source/README.md)。
