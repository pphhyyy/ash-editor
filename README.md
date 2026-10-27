# ASH 2.0.1

- 可运行 app：`ASH.app`（显示名称为 ASH；版本 2.0.1 可从“关于 ASH”查看）
- 完整源码和离线依赖：`source/`

编译需要 macOS 14 或更新版本、Xcode、XcodeGen 和 Node.js 22。Node.js 可从系统 `PATH` 中调用；源码压缩包自带前端依赖，不依赖本目录之外的工具或文件。

2.0.1 基于 2.0，修复切换 `$` 与反斜杠公式定界符后的预览解析，并规范单行显示公式的预览格式。

构建方法和具体实现记录见 [`source/README.md`](source/README.md)。
