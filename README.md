# ASH 2.0 独立实验版

- 可运行 app：`ASH.app`（显示名称为 ASH；版本 2.0 可从“关于 ASH”查看）
- 完整源码和离线依赖：`source/`
- 本版本源码和前端依赖：`source/`

编译需要 macOS 14 或更新版本、Xcode、XcodeGen 和 Node.js 22。Node.js 可从系统 `PATH` 中调用；源码压缩包自带前端依赖，不依赖本目录之外的工具或文件。

2.0 是从 build18 / ASH 1.0 源码复制出来的独立目录。图片居中、右键左对齐、右下角拖拽缩放、`.ashj` / `.ashp` 加密资源和 KaTeX 公式预览的修改都在 `source/` 中；1.0 目录未改。

构建方法和具体实现记录见 [`source/README.md`](source/README.md)。
