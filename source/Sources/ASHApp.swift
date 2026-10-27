import SwiftUI
import AppKit
import Combine

@main
struct ASHApp: App {
    @NSApplicationDelegateAdaptor(AshAppDelegate.self) private var appDelegate
    @AppStorage("ash.splitMode") private var splitMode = "off"
    @AppStorage("ash.textAlignment") private var alignment = "left"
    var body: some Scene {
        WindowGroup {
            ScaledEditorWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建笔记") { NotificationCenter.default.post(name: .ashNew, object: nil) }
            }
            CommandGroup(after: .saveItem) {
                Button("打开文档…") { NotificationCenter.default.post(name: .ashOpen, object: nil) }
                Button("保存") { NotificationCenter.default.post(name: .ashSave, object: nil) }
                Button("另存为…") { NotificationCenter.default.post(name: .ashSaveAs, object: nil) }
                Button("导出为 Markdown…") { NotificationCenter.default.post(name: .ashExportMarkdown, object: nil) }
            }
            CommandMenu("标签页") {
                Button("新建标签页") { NotificationCenter.default.post(name: .ashNew, object: nil) }
                Button("关闭当前标签页") { NotificationCenter.default.post(name: .ashEditorCommand, object: "tab:close") }
                Divider()
                Button("下一个标签页") { NotificationCenter.default.post(name: .ashEditorCommand, object: "tab:next") }
                Button("上一个标签页") { NotificationCenter.default.post(name: .ashEditorCommand, object: "tab:previous") }
            }
            CommandMenu("视图") {
                Button("切换预览 / 普通输入") { NotificationCenter.default.post(name: .ashEditorCommand, object: "preview") }
                Divider()
                Button {
                    splitMode = "sideBySide"
                    NotificationCenter.default.post(name: .ashEditorCommand, object: "split:sideBySide")
                } label: {
                    Label("左右双文档", systemImage: splitMode == "sideBySide" ? "checkmark" : "rectangle.split.2x1")
                }
                Button {
                    splitMode = "stacked"
                    NotificationCenter.default.post(name: .ashEditorCommand, object: "split:stacked")
                } label: {
                    Label("上下双文档", systemImage: splitMode == "stacked" ? "checkmark" : "rectangle.split.1x2")
                }
                Button {
                    splitMode = "off"
                    NotificationCenter.default.post(name: .ashEditorCommand, object: "split:off")
                } label: {
                    Label("单文档模式", systemImage: splitMode == "off" ? "checkmark" : "rectangle")
                }
                Divider()
                Button {
                    NotificationCenter.default.post(name: .ashEditorCommand, object: "center")
                } label: {
                    Label("居中模式", systemImage: alignment == "center" ? "checkmark" : "text.aligncenter")
                }
                Button("渐隐文字") { NotificationCenter.default.post(name: .ashEditorCommand, object: "privacy:fade") }
                Button("隐私模式") { NotificationCenter.default.post(name: .ashEditorCommand, object: "privacy") }
                Button("纯净模式") { NotificationCenter.default.post(name: .ashEditorCommand, object: "focus") }
                Button("聊天框模式") { NotificationCenter.default.post(name: .ashEditorCommand, object: "chat") }
                Button("切换聊天框置顶") { NotificationCenter.default.post(name: .ashEditorCommand, object: "chat:pin") }
            }
            CommandMenu("格式") {
                Button("增大字号") { NotificationCenter.default.post(name: .ashEditorCommand, object: "font:up") }
                Button("减小字号") { NotificationCenter.default.post(name: .ashEditorCommand, object: "font:down") }
            }
        }
    }
}

@MainActor
final class AshAppDelegate: NSObject, NSApplicationDelegate {
    private var preparingToQuit = false
    private var quitApproved = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitApproved || !ApplicationQuitGuard.shared.hasParticipants { return .terminateNow }
        guard !preparingToQuit else {
            sender.activate(ignoringOtherApps: true)
            return .terminateCancel
        }
        preparingToQuit = true
        // Keep the normal event loop running while SwiftUI presents save prompts.
        // AppKit's terminateLater state can prevent those prompts from appearing.
        DispatchQueue.main.async { [weak self] in
            ApplicationQuitGuard.shared.prepareToQuit { [weak self] allowed in
                guard let self else { return }
                self.preparingToQuit = false
                guard allowed else { return }
                self.quitApproved = true
                sender.terminate(nil)
            }
        }
        return .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The explicit Info.plist supplies Finder's icon. Refresh the running
        // app as well, so Dock does not retain an earlier generic build's icon.
        if let iconURL = Bundle.main.url(forResource: "ASHHanddrawn", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.localizeMenuTitles() }
        #if DEBUG
        // QA-only: open a fixture without the system panel so UI tests exercise the real editor and save paths.
        if let path = ProcessInfo.processInfo.environment["ASH_QA_OPEN_FILE"], FileManager.default.fileExists(atPath: path) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                NotificationCenter.default.post(name: .ashOpenURL, object: URL(fileURLWithPath: path))
            }
        }
        #endif
    }

    /// Open .md / .ash documents handed over by LaunchServices (double-click, `open -a`, Dock drop).
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        // The SwiftUI window may still be restoring when a launch-time open arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            NotificationCenter.default.post(name: .ashOpenURL, object: url)
        }
    }

    private func localizeMenuTitles() {
        let translations = [
            "File": "文件", "Edit": "编辑", "Insert": "插入", "View": "视图", "Format": "格式",
            "Window": "窗口", "Help": "帮助", "Services": "服务",
            "About ASH": "关于 ASH", "Preferences…": "偏好设置…", "Settings…": "偏好设置…",
            "Hide ASH": "隐藏 ASH", "Hide Others": "隐藏其他应用", "Show All": "显示全部",
            "Quit ASH": "退出 ASH", "Minimize": "最小化", "Zoom": "缩放",
            "Bring All to Front": "全部移到最前", "Undo": "撤销", "Redo": "重做",
            "Cut": "剪切", "Copy": "拷贝", "Paste": "粘贴", "Delete": "删除",
            "Select All": "全选", "Find": "查找", "Find and Replace…": "查找和替换…",
            "Spelling and Grammar": "拼写和语法", "Substitutions": "替换", "Transformations": "转换",
            "Speech": "语音", "Emoji & Symbols": "表情与符号", "Close Window": "关闭窗口",
            "New Window": "新建窗口", "Open Recent": "打开最近使用的项目", "Clear Menu": "清除菜单",
            "Print…": "打印…"
        ]
        func translate(_ menu: NSMenu) {
            for item in menu.items {
                if let translated = translations[item.title] { item.title = translated }
                if let submenu = item.submenu { translate(submenu) }
            }
        }
        if let mainMenu = NSApp.mainMenu { translate(mainMenu) }
    }
}

extension Notification.Name {
    static let ashNew = Notification.Name("ash.new")
    static let ashOpen = Notification.Name("ash.open")
    static let ashSaveAs = Notification.Name("ash.saveAs")
    static let ashSave = Notification.Name("ash.save")
    static let ashExportMarkdown = Notification.Name("ash.exportMarkdown")
    static let ashEditorCommand = Notification.Name("ash.editorCommand")
    static let ashOpenURL = Notification.Name("ash.openURL")
}

