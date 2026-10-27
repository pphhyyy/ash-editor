# ASH 2.0.5

- 可运行 app：`ASH.app`（显示名称为 ASH；版本 2.0.5 可从“关于 ASH”查看）
- 完整源码和离线依赖：`source/`

编译需要 macOS 14 或更新版本、Xcode、XcodeGen 和 Node.js 22。Node.js 可从系统 `PATH` 中调用；源码压缩包自带前端依赖，不依赖本目录之外的工具或文件。

2.0.5 build 8 修复大字号和松散列表中，编号与列表正文首行错位的问题。列表标记高度随正文行高缩放，并移除首段多余的顶部留白；紫雾、纸感和夜色主题共用此布局。该版本也保留了 2.0.4 build 7 对 GPT 公式粘贴的修复。

构建方法和具体实现记录见 [`source/README.md`](source/README.md)。
