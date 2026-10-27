import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MarkdownUI

private enum AshTheme: String, CaseIterable, Identifiable {
    case purple = "紫雾", paper = "纸感", night = "夜色"
    var id: String { rawValue }
    static func restoreSelection() -> AshTheme {
        let saved = UserDefaults.standard.string(forKey: "ash.selectedTheme")
        return allCases.first { $0.rawValue == saved } ?? .purple
    }
    var background: Color {
        switch self {
        case .purple: Color(red: 0.965, green: 0.949, blue: 0.985)
        case .paper: Color(red: 0.985, green: 0.974, blue: 0.946)
        case .night: Color(red: 0.212, green: 0.231, blue: 0.251)
        }
    }
    var paper: Color {
        switch self {
        case .purple: Color.white.opacity(0.84)
        case .paper: Color(red: 1, green: 0.995, blue: 0.976)
        case .night: Color(red: 0.173, green: 0.184, blue: 0.196)
        }
    }
    var ink: Color { self == .night ? Color(red: 0.88, green: 0.89, blue: 0.90) : Color(red: 0.22, green: 0.19, blue: 0.28) }
    var muted: Color { self == .night ? .white.opacity(0.58) : Color(red: 0.56, green: 0.52, blue: 0.62) }
}

private enum AshSaveMode: String, CaseIterable, Identifiable {
    case local, personal
    var id: String { rawValue }
    var title: String { self == .local ? "本机便捷加密（默认）" : "个人密码（跨设备）" }
}

private enum AshSplitMode: String, CaseIterable, Identifiable {
    case off, sideBySide, stacked
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "默认布局"
        case .sideBySide: "左右双文档"
        case .stacked: "上下双文档"
        }
    }
}

private enum AshDocumentPane: Equatable {
    case primary
    case secondary
}

private struct EditorContentSnapshot: Equatable {
    var title = ""
    var markdown = ""
}

private struct PendingDocumentOpen {
    let url: URL?
    let secondary: Bool
}

/// Inactive tabs retain their complete in-memory save target and credential.
/// The selected tab uses the existing editor bindings and save implementation.
private struct EditorTab: Identifiable {
    let id: UUID
    var title = ""
    var markdown = ""
    var fileURL: URL?
    var sourceURL: URL?
    var saved = EditorContentSnapshot()
    var storage: DocumentStorage = .defaultEncrypted
    var saveMode: AshSaveMode = .local
    var placeholder: Bool
    init(id: UUID = UUID(), placeholder: Bool = true) { self.id = id; self.placeholder = placeholder }
    var dirty: Bool { EditorContentSnapshot(title: title, markdown: markdown) != saved }
    var isEmpty: Bool { title.isEmpty && markdown.isEmpty && sourceURL == nil && !dirty }
}

private struct TabReference {
    let id: UUID
    let pane: AshDocumentPane
}

struct EditorView: View {
    @State private var title = ""
    @State private var markdown = ""
    @State private var secondaryTitle = ""
    @State private var secondaryMarkdown = ""
    @State private var primaryFocusToken = 0
    @State private var secondaryFocusToken = 0
    @AppStorage("ash.defaultFontSize") private var fontSize = 18.0
    @AppStorage("ash.mathDelimiter") private var mathDelimiter = "dollar"
    @AppStorage("ash.livePreviewEnabled") private var livePreviewEnabled = true
    @AppStorage("ash.uiScale") private var uiScale = 1.0
    @AppStorage("ash.textAlignment") private var alignment = "left"
    @AppStorage("ash.splitMode") private var splitModeRaw = AshSplitMode.off.rawValue
    @AppStorage("ash.pageMargin") private var pageMargin = 48.0
    @State private var theme: AshTheme = AshTheme.restoreSelection()
    @State private var canvasColor = AshTheme.restoreSelection().background
    @State private var fontColor = AshTheme.restoreSelection().ink
    @State private var privacy = false
    @State private var fadingPrivacy = false
    @AppStorage("ash.fadeInitialOpacity") private var fadeInitialOpacity = 0.35
    @AppStorage("ash.fadeDuration") private var fadeDuration = 4.0
    @State private var showingPreview = false
    @State private var focusMode = false
    @State private var chatMode = false
    @State private var editorWindow: NSWindow?
    @State private var showingPreferences = false
    @State private var showingShortcutSettings = false
    @State private var exportForSecondary = false
    @State private var showingUnsavedPrompt = false
    @StateObject private var shortcuts = FocusShortcutController()
    @State private var showingPassword = false
    @State private var pendingOpen = false
    @State private var saveMode: AshSaveMode = .local
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var fileURL: URL?
    @State private var secondaryFileURL: URL?
    @State private var primarySourceURL: URL?
    @State private var secondarySourceURL: URL?
    @State private var pendingOpenURL: URL?
    @State private var pendingTrashURL: URL?
    @State private var showingTrashConfirmation = false
    @State private var pendingDocumentOpen: PendingDocumentOpen?
    @State private var showingDocumentSwitchPrompt = false
    @State private var saveBeforeOpening = false
    @StateObject private var folderWorkspace = FolderWorkspace()
    @StateObject private var recentIndex = RecentDocumentIndex()
    @State private var hoveredRecentPath: String?
    @AppStorage("ash.sidebar.recentExpanded") private var recentExpanded = true
    @AppStorage("ash.sidebar.folderExpanded") private var folderExpanded = true
    @State private var activePane: AshDocumentPane = .primary
    @State private var status = "本地加密 · 由你掌管"
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var savedPrimary = EditorContentSnapshot()
    @State private var savedSecondary = EditorContentSnapshot()
    @State private var closeAfterSave = false
    @State private var closeInterceptor = UnsavedCloseInterceptor()
    @State private var pendingSecondary = false
    @State private var secondarySaveMode: AshSaveMode = .local
    @State private var primaryStorage: DocumentStorage = .defaultEncrypted
    @State private var secondaryStorage: DocumentStorage = .defaultEncrypted
    @State private var saveAsMarkdown = false
    @StateObject private var compactWindow = CompactWritingWindow()
    @State private var primaryTabs = [EditorTab()]
    @State private var secondaryTabs = [EditorTab()]
    @State private var primaryTabIndex = 0
    @State private var secondaryTabIndex = 0
    @State private var pendingTabClose: TabReference?
    @State private var showingTabClosePrompt = false
    @State private var closeTabAfterSaving: TabReference?
    @State private var terminationID = UUID()
    @State private var quitReply: ((Bool) -> Void)?

    private let purple = Color(red: 0.48, green: 0.35, blue: 0.83)
    private var activeMarkdown: String { activePane == .secondary ? secondaryMarkdown : markdown }
    private var wordCount: Int {
        // Count each CJK ideograph as one character and each Latin/numeric run as one word.
        let pattern = #"[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}]|[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(activeMarkdown.startIndex..<activeMarkdown.endIndex, in: activeMarkdown)
        return regex.numberOfMatches(in: activeMarkdown, range: range)
    }
    private var splitMode: AshSplitMode { AshSplitMode(rawValue: splitModeRaw) ?? .off }
    private var ashSuggestedFilename: String {
        let name = (exportForSecondary ? secondaryTitle : title).trimmingCharacters(in: .whitespacesAndNewlines)
        return ashBaseName(name.isEmpty ? "未命名" : name)
    }
    private var markdownSuggestedFilename: String {
        let name = (exportForSecondary ? secondaryTitle : title).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? "未命名" : name) + ".md"
    }
    private var hasUnsavedChanges: Bool {
        !dirtyTabs.isEmpty
    }

    private var editorSurface: some View {
        HStack(spacing: 0) {
            if !focusMode { sidebar }
            VStack(spacing: 0) {
                if !focusMode {
                    titleBar
                }
                workspace
                if !focusMode { statusBar }
            }
        }
        .background(canvasColor.ignoresSafeArea())
        .background(EditorWindowCloseHook(interceptor: closeInterceptor) { window in
            editorWindow = window
            // Focus-mode dragging is scoped to blank areas in the tab bar.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovable = true
            window.isMovableByWindowBackground = false
            closeInterceptor.attach(to: window, hasUnsavedChanges: { hasUnsavedChanges },
                                    prompt: { showingUnsavedPrompt = true },
                                    didClose: { cleanupEditor() })
            ApplicationQuitGuard.shared.attach(id: terminationID, window: window) { completion in
                guard window.attachedSheet == nil else { completion(false); return }
                if chatMode { closeChatMode() }
                LiveMarkdownEditors.flush {
                    if hasUnsavedChanges {
                        quitReply = completion
                        showingUnsavedPrompt = true
                    } else { completion(true) }
                }
            }
        })
        .preferredColorScheme(theme == .night ? .dark : .light)
        .sheet(isPresented: $showingPassword) { passwordSheet }
        // Keep the presenting view subscribed to the sheet's initial configuration.
        .onChange(of: saveAsMarkdown) { _, _ in }
        .onChange(of: pendingOpen) { _, _ in }
        .sheet(isPresented: $showingShortcutSettings) { FocusShortcutSettings(shortcuts: shortcuts) }
        .sheet(isPresented: $showingPreferences) { preferencesSheet }
        .alert("操作未完成", isPresented: $showingError) { Button("好", role: .cancel) {} } message: { Text(errorMessage) }
        .alert("保存此标签页的修改？", isPresented: $showingTabClosePrompt) {
            Button("保存") {
                guard let target = pendingTabClose else { return }
                activateTab(target) {
                    closeTabAfterSaving = target
                    savePanel(forSecondary: target.pane == .secondary)
                }
            }
            Button("不保存", role: .destructive) {
                if let target = pendingTabClose { removeTab(target) }
                pendingTabClose = nil
            }
            Button("取消", role: .cancel) { pendingTabClose = nil }
        } message: {
            Text("该文档有未保存的修改。取消将保留标签页和编辑内容。")
        }
        .alert("将文件移到废纸篓？", isPresented: $showingTrashConfirmation) {
            Button("取消", role: .cancel) { pendingTrashURL = nil }
            Button("移到废纸篓", role: .destructive) {
                if let url = pendingTrashURL { trashDocument(url) }
                pendingTrashURL = nil
            }
        } message: {
            Text("“\(pendingTrashURL?.lastPathComponent ?? "")”将从磁盘移到废纸篓。当前已打开的内容会保留在编辑器中。")
        }
        .alert("要先保存当前文档的更改吗？", isPresented: $showingDocumentSwitchPrompt) {
            Button("保存并继续") {
                if let request = pendingDocumentOpen {
                    saveBeforeOpening = true
                    savePanel(forSecondary: request.secondary)
                }
            }
            Button("不保存，继续", role: .destructive) {
                if let request = pendingDocumentOpen {
                    pendingDocumentOpen = nil
                    performOpenDocument(request)
                }
            }
            Button("取消", role: .cancel) { cancelPendingDocumentOpen() }
        } message: {
            Text("当前文档有尚未保存的修改。保存后再继续，可保留这些内容。")
        }
        .overlay {
            if showingUnsavedPrompt { unsavedPromptOverlay.transition(.opacity) }
        }
        .onChange(of: theme) { _, selection in
            UserDefaults.standard.set(selection.rawValue, forKey: "ash.selectedTheme")
            canvasColor = selection.background
            fontColor = selection.ink
        }
    }

    var body: some View {
        editorSurface
        .onAppear {
            showingPreview = false
            shortcuts.install { action in
                guard !showingUnsavedPrompt && !showingTabClosePrompt else { return }
                switch action {
                case .newDocument: requestNewDocument()
                case .newTab: requestNewDocument()
                case .closeTab: requestCloseActiveTab()
                case .nextTab: cycleTab(1)
                case .previousTab: cycleTab(-1)
                case .open: openPanel(forSecondary: activePane == .secondary)
                case .save: savePanel(forSecondary: activePane == .secondary)
                case .saveAs: saveAsPanel(forSecondary: activePane == .secondary)
                case .exportMarkdown: exportMarkdown()
                case .preview: handleEditorCommand("preview")
                case .livePreview: setLivePreviewEnabled(!livePreviewEnabled)
                case .splitLeftRight: handleEditorCommand("split:sideBySide")
                case .splitTopBottom: handleEditorCommand("split:stacked")
                case .singleDocument: handleEditorCommand("split:off")
                case .center: handleEditorCommand("center")
                case .fadingPrivacy: toggleFadingPrivacy()
                case .privacy: togglePrivacyMode()
                case .focus: toggleFocusMode()
                case .chat: toggleChatMode()
                case .pinChat: compactWindow.togglePinned()
                case .fontUp: fontSize = min(32, fontSize + 1)
                case .fontDown: fontSize = max(13, fontSize - 1)
                }
            }
        }
        .onDisappear(perform: cleanupEditor)
        .onReceive(NotificationCenter.default.publisher(for: .ashNew)) { _ in requestNewDocument() }
        .onReceive(NotificationCenter.default.publisher(for: .ashOpen)) { _ in openPanel(forSecondary: activePane == .secondary) }
        .onReceive(NotificationCenter.default.publisher(for: .ashOpenURL)) { note in
            guard let url = note.object as? URL else { return }
            requestOpenDocument(url, toSecondary: activePane == .secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ashSave)) { _ in savePanel(forSecondary: activePane == .secondary) }
        .onReceive(NotificationCenter.default.publisher(for: .ashSaveAs)) { _ in saveAsPanel(forSecondary: activePane == .secondary) }
        .onChange(of: fontSize) { _, value in compactWindow.fontSize = value }
        .onChange(of: alignment) { _, value in compactWindow.alignment = value }
        .onChange(of: fontColor) { _, value in compactWindow.ink = value }
        .onChange(of: canvasColor) { _, value in compactWindow.canvas = value }
        .onChange(of: fadeInitialOpacity) { _, value in compactWindow.fadeInitialOpacity = value }
        .onChange(of: fadeDuration) { _, value in compactWindow.fadeDuration = value }
        .onReceive(NotificationCenter.default.publisher(for: .ashExportMarkdown)) { _ in exportMarkdown() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            folderWorkspace.refresh()
            recentIndex.reload()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            if NSApp.isActive && folderExpanded { folderWorkspace.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ashEditorCommand)) { note in
            if let command = note.object as? String { handleEditorCommand(command) }
        }
    }

    private var titleBar: some View {
        let currentTitle = activePane == .secondary ? secondaryTitle : title
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(purple)
                Text((privacy || fadingPrivacy) ? "私密文档" : (currentTitle.isEmpty ? "无标题笔记" : currentTitle))
                    .lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(fontColor)
            .frame(maxWidth: 180, alignment: .leading)
            Spacer(minLength: 8)
            Button(action: requestNewDocument) { Image(systemName: "square.and.pencil") }
                .buttonStyle(AshToolbarButton()).help("新建笔记").accessibilityLabel("新建笔记")
            Button(action: { openPanel(forSecondary: activePane == .secondary) }) { Label("打开", systemImage: "folder") }
                .buttonStyle(AshToolbarButton())
            Button(action: { savePanel(forSecondary: activePane == .secondary) }) {
                Label("保存", systemImage: "lock.shield.fill")
            }.buttonStyle(AshPrimaryButton(color: purple))
                .help("保存到原位置；另存为可选择格式和密码")
                .accessibilityLabel("保存")
            Button { saveAsPanel(forSecondary: activePane == .secondary) } label: {
                Label("另存为", systemImage: "doc.badge.plus")
            }
            .buttonStyle(AshToolbarButton()).help("另存为…").accessibilityLabel("另存为")
            Button(action: exportMarkdown) { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(AshToolbarButton()).help("导出 Markdown").accessibilityLabel("导出 MD")
            Menu {
                Button { togglePrivacyMode() } label: {
                    Label(privacy ? "显示正文内容" : "隐藏正文内容", systemImage: privacy ? "eye" : "eye.slash")
                }
                Button { toggleFadingPrivacy() } label: {
                    Label(fadingPrivacy ? "关闭渐隐文字" : "渐隐文字", systemImage: "eye.trianglebadge.exclamationmark")
                }
                Button { toggleFocusMode() } label: {
                    Label(focusMode ? "切换到普通模式" : "切换到纯净模式", systemImage: "rectangle.and.pencil.and.ellipsis")
                }
                Button { toggleChatMode() } label: {
                    Label("聊天框模式", systemImage: "rectangle.bottomthird.inset.filled")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(AshToolbarButton())
            .help("隐私、纯净与聊天框模式").accessibilityLabel("模式")
            .fixedSize()
            Menu {
                Button("左右分栏") { setSplitLayout(.sideBySide) }
                Button("上下分栏") { setSplitLayout(.stacked) }
                Button("合并为单栏") { setSplitLayout(.off) }
            } label: { Image(systemName: "rectangle.split.2x1") }
            .menuStyle(.borderlessButton).buttonStyle(AshToolbarButton())
            .help("文档分栏").accessibilityLabel("文档分栏").fixedSize()
            Button { showingPreferences = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(AshToolbarButton()).help("偏好设置").accessibilityLabel("偏好设置")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(theme.paper.opacity(0.75))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.ink.opacity(0.07)).frame(height: 1) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("工作区").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.ink)
                .padding(.horizontal, 13).padding(.top, 52)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    recentSidebar
                    folderSidebar
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(width: 230).frame(maxHeight: .infinity, alignment: .top)
        .background(theme.background.opacity(0.82))
        .overlay(alignment: .trailing) { Rectangle().fill(theme.ink.opacity(0.07)).frame(width: 1) }
    }

    private var recentSidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                sidebarSectionHeader("最近文档", expanded: $recentExpanded)
                Text("\(recentIndex.documents.count)")
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(theme.muted)
                Button { revealDocument(recentIndex.indexURL) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(purple)
                    .help("在访达中显示最近文档索引 recent-documents.json")
                    .accessibilityLabel("显示最近文档索引文件")
            }
            if recentExpanded {
                if let message = recentIndex.errorMessage {
                    Text(message).font(.system(size: 10)).foregroundStyle(theme.muted)
                }
                if recentIndex.documents.isEmpty {
                    Text("暂无最近文档").font(.system(size: 10)).foregroundStyle(theme.muted).padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(recentIndex.documents) { entry in
                                recentDocumentRow(entry)
                            }
                        }.padding(4)
                    }
                    .frame(height: min(112, CGFloat(recentIndex.documents.count) * 27 + 8))
                    .background(theme.paper, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func recentDocumentRow(_ entry: RecentDocumentEntry) -> some View {
        let url = recentIndex.resolvedURL(for: entry)
        let source = activePane == .secondary ? secondarySourceURL : primarySourceURL
        let highlighted = hoveredRecentPath == entry.path || source?.standardizedFileURL == url.standardizedFileURL
        return Button { openRecent(url) } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(purple)
                Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .foregroundStyle(fontColor).padding(.horizontal, 7).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? purple.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredRecentPath = $0 ? entry.path : nil }
        .help(url.path + "\n最近打开：" + entry.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))
        .contextMenu {
            Button("在访达中显示") { revealDocument(url) }
            Button("删除记录") { removeRecentDocument(url) }
        }
    }

    private func sidebarSectionHeader(_ text: String, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold)).frame(width: 9)
                Text(text).font(.system(size: 10, weight: .semibold)).tracking(0.5)
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.muted).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityLabel(text + (expanded.wrappedValue ? "，已展开" : "，已折叠"))
    }

    private var folderSidebar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                sidebarSectionHeader("当前文件夹", expanded: $folderExpanded)
                Button(action: openFolderPanel) { Image(systemName: "folder.badge.plus") }
                    .help("打开或更换文件夹").accessibilityLabel("打开文件夹")
                if folderWorkspace.rootURL != nil {
                    Button { folderWorkspace.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .help("刷新文件夹").accessibilityLabel("刷新文件夹")
                    Button { folderWorkspace.close() } label: { Image(systemName: "xmark") }
                        .help("关闭当前文件夹").accessibilityLabel("关闭当前文件夹")
                }
            }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(purple)
            if folderExpanded {
                if let root = folderWorkspace.rootURL {
                    Label(root.lastPathComponent, systemImage: "folder.fill")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(fontColor)
                        .lineLimit(1).help(root.path)
                        .contextMenu { Button("在访达中显示") { revealDocument(root) } }
                    if let message = folderWorkspace.errorMessage {
                        Text(message).font(.system(size: 10)).foregroundStyle(theme.muted)
                    } else if folderWorkspace.nodes.isEmpty {
                        Text("没有 ASH / Markdown 文件").font(.system(size: 10)).foregroundStyle(theme.muted).padding(.vertical, 6)
                    } else {
                        VStack(spacing: 2) {
                            ForEach(folderWorkspace.nodes) { node in
                                WorkspaceFileTreeRow(node: node, folder: folderWorkspace,
                                    selectedURL: activePane == .secondary ? secondarySourceURL : primarySourceURL,
                                    accent: purple, ink: fontColor,
                                    onOpen: { openSidebarDocument($0) }, onReveal: revealDocument, onTrash: confirmTrash)
                            }
                        }
                    }
                } else {
                    Text(folderWorkspace.errorMessage ?? "打开文件夹，浏览其中的 ASH 和 Markdown 文档。")
                        .font(.system(size: 10)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
                    Button(action: openFolderPanel) { Label("打开文件夹…", systemImage: "folder") }
                        .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(purple).padding(.vertical, 4)
                }
            }
        }
    }

    private var workspace: some View {
        Group {
            if splitMode == .off {
                documentPane(.primary)
            } else if splitMode == .sideBySide {
                HSplitView {
                    documentPane(.primary).frame(minWidth: 220)
                    documentPane(.secondary).frame(minWidth: 220)
                }.padding(focusMode ? 0 : 8)
            } else {
                VSplitView {
                    documentPane(.primary).frame(minHeight: 160)
                    documentPane(.secondary).frame(minHeight: 160)
                }.padding(focusMode ? 0 : 8)
            }
        }
        .background(canvasColor)
    }

    private func documentPane(_ pane: AshDocumentPane) -> some View {
        let secondary = pane == .secondary
        let paneDocumentID = selectedTabID(pane)
        let paneTitle = secondary ? $secondaryTitle : $title
        let paneMarkdown = secondary ? $secondaryMarkdown : $markdown
        let paneURL = secondary ? secondaryFileURL : fileURL
        let paneStorage = secondary ? secondaryStorage : primaryStorage
        let imageWorkspaceRoot = folderWorkspace.rootURL
        return VStack(spacing: 0) {
            tabBar(pane)
            Group {
                if showingPreview && !privacy && !fadingPrivacy {
                    // Use the same Markdown grammar and palette for editing and
                    // reading, including Obsidian highlight marks.
                    LiveMarkdownEditor(text: paneMarkdown, size: fontSize, color: fontColor,
                        isNight: theme == .night, themeName: theme.rawValue, readOnly: true,
                        concealed: false, documentTitle: paneTitle, showsDocumentTitle: true,
                        fading: false, fadeInitialOpacity: fadeInitialOpacity, fadeDuration: fadeDuration,
                        alignment: alignment, pageMargin: pageMargin, secondary: secondary,
                        mathDelimiter: mathDelimiter,
                        loadImage: { reference in
                            try ASHImageAssets.load(reference, documentURL: paneURL, workspaceRoot: imageWorkspaceRoot, storage: paneStorage,
                                readData: { assetURL in try withFileAccess(assetURL) { try Data(contentsOf: $0) } })
                        },
                        isCurrent: { selectedTabID(pane) == paneDocumentID },
                        wantsFocus: { false }, onFocus: { activePane = pane },
                        pasteImage: {
                            guard let image = ASHImageAssets.imageFromPasteboard() else { return nil }
                            return try ASHImageAssets.storeDraft(image.data, mimeType: image.mimeType, in: imageWorkspaceRoot)
                        },
                        onError: { message in errorMessage = message; showingError = true })
                        .id(selectedTabID(pane))
                } else {
                    inputEditor(paneMarkdown, secondary: secondary, focus: focusMode)
                        .padding(.top, focusMode ? 4 : 12)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onDrop(of: [ASHEditorDragType.tab, ASHEditorDragType.file], delegate: DocumentPaneDropDelegate(
                moveTab: { moveDroppedTab($0, to: pane, before: nil) },
                openFile: { openDroppedFile($0, in: pane) }
            ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.paper)
        .clipped()
    }

    @ViewBuilder
    private func inputEditor(_ value: Binding<String>, secondary: Bool, focus: Bool) -> some View {
        let pane: AshDocumentPane = secondary ? .secondary : .primary
        let documentID = selectedTabID(pane)
        let paneURL = secondary ? secondaryFileURL : fileURL
        let paneStorage = secondary ? secondaryStorage : primaryStorage
        let imageWorkspaceRoot = folderWorkspace.rootURL
        if livePreviewEnabled {
            LiveMarkdownEditor(text: value, size: fontSize, color: fontColor, isNight: theme == .night, themeName: theme.rawValue, concealed: privacy,
                               documentTitle: secondary ? $secondaryTitle : $title, showsDocumentTitle: true,
                               fading: fadingPrivacy, fadeInitialOpacity: fadeInitialOpacity, fadeDuration: fadeDuration,
                               alignment: alignment, pageMargin: pageMargin, secondary: secondary,
                               mathDelimiter: mathDelimiter,
                               loadImage: { reference in
                                   try ASHImageAssets.load(reference, documentURL: paneURL, workspaceRoot: imageWorkspaceRoot, storage: paneStorage,
                                       readData: { assetURL in try withFileAccess(assetURL) { try Data(contentsOf: $0) } })
                               },
                               isCurrent: { selectedTabID(pane) == documentID },
                               wantsFocus: { activePane == pane },
                               onFocus: { activePane = secondary ? .secondary : .primary },
                               pasteImage: {
                                   guard let image = ASHImageAssets.imageFromPasteboard() else { return nil }
                                   return try ASHImageAssets.storeDraft(image.data, mimeType: image.mimeType, in: imageWorkspaceRoot)
                               },
                               onError: { message in
                livePreviewEnabled = false
                errorMessage = message
                showingError = true
            })
            .id(documentID)
        } else {
            AshTextEditor(text: value, size: fontSize, color: fontColor, concealed: privacy,
                          focusMode: focus, alignment: alignment, pageMargin: pageMargin,
                          documentTitle: secondary ? $secondaryTitle : $title, showsDocumentTitle: true,
                          fading: fadingPrivacy, fadeInitialOpacity: fadeInitialOpacity, fadeDuration: fadeDuration,
                          isCurrent: { selectedTabID(pane) == documentID },
                          wantsFocus: { activePane == pane },
                          onFocus: { activePane = secondary ? .secondary : .primary },
                          focusToken: activePane == pane ? (secondary ? secondaryFocusToken : primaryFocusToken) : 0,
                          pasteImage: {
                              guard let image = ASHImageAssets.imageFromPasteboard() else { return nil }
                              return try ASHImageAssets.storeDraft(image.data, mimeType: image.mimeType, in: imageWorkspaceRoot)
                          },
                          onError: { message in errorMessage = message; showingError = true })
            .id(documentID)
        }
    }

    private func setLivePreviewEnabled(_ enabled: Bool) {
        guard livePreviewEnabled != enabled else { return }
        LiveMarkdownEditors.flush {
            livePreviewEnabled = enabled
            showingPreview = false
        }
    }

    private var statusBar: some View {
        HStack {
            Image(systemName: "lock.fill").foregroundStyle(purple)
            Text(privacy ? "隐私模式已开启" : (fadingPrivacy ? "渐隐模式已开启" : status)).foregroundStyle(theme.muted)
            Spacer()
            Text("字数：\(wordCount)").monospacedDigit().foregroundStyle(theme.muted)
            Text("·").foregroundStyle(theme.muted)
            let activeURL = activePane == .secondary ? secondaryFileURL : fileURL
            Text(activeURL?.lastPathComponent ?? "尚未保存").foregroundStyle(theme.muted).lineLimit(1)
            let current = EditorContentSnapshot(title: activePane == .secondary ? secondaryTitle : title, markdown: activeMarkdown)
            if current != (activePane == .secondary ? savedSecondary : savedPrimary) {
                Text("未保存修改").foregroundStyle(purple)
            }
        }.font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 22)
            .frame(height: 36)
            .background(theme.paper.opacity(0.7))
            .overlay(alignment: .top) { Rectangle().fill(theme.ink.opacity(0.07)).frame(height: 1) }
    }

    private var preferencesSheet: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Label("偏好设置", systemImage: "slider.horizontal.3").font(.system(size: 19, weight: .semibold))
            Picker("主题", selection: $theme) { ForEach(AshTheme.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
            GroupBox("数学公式") {
                VStack(alignment: .leading, spacing: 7) {
                    Picker("公式分隔符", selection: $mathDelimiter) {
                        Text("$…$ / $$…$$").tag("dollar")
                        Text("\\(…\\) / \\[…\\]").tag("latex")
                    }.pickerStyle(.segmented)
                    Text("选择后会转换当前文档中公式的 Markdown 写法；公式在编辑器中使用 KaTeX 预览。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(6)
            }
            GroupBox("渐隐文字") {
                VStack(alignment: .leading, spacing: 9) {
                    Toggle("开启渐隐", isOn: Binding(get: { fadingPrivacy }, set: { _ in toggleFadingPrivacy() }))
                    HStack {
                        Text("起始可见度")
                        Slider(value: $fadeInitialOpacity, in: 0.05...0.8, step: 0.05)
                        Text("\(Int(fadeInitialOpacity * 100))%").monospacedDigit().frame(width: 42)
                    }
                    HStack {
                        Text("完全隐藏用时")
                        Slider(value: $fadeDuration, in: 1...15, step: 0.5)
                        Text(String(format: "%.1f 秒", fadeDuration)).monospacedDigit().frame(width: 48)
                    }
                    Text("已有文字立即隐藏；新输入的文字从浅色逐渐淡出。即时隐藏仍可单独使用。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(6)
            }
            ColorPicker("背景颜色", selection: $canvasColor, supportsOpacity: false)
            ColorPicker("字体颜色", selection: $fontColor, supportsOpacity: false)
            HStack {
                Text("正文字号"); Slider(value: $fontSize, in: 13...32, step: 1); Text("\(Int(fontSize)) pt").monospacedDigit()
            }
            HStack {
                Text("界面缩放")
                Slider(value: $uiScale, in: 0.75...1.5, step: 0.05)
                Text("\(Int((uiScale * 100).rounded()))%").monospacedDigit().frame(width: 45)
                Button("重置") { uiScale = 1.0 }
            }
            Text("界面缩放调整整体界面比例；正文字号单独调整编辑内容，两项独立保存。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text("页面边距")
                Slider(value: $pageMargin, in: 16...120, step: 4)
                Text("\(Int(pageMargin)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
            Text("调整编辑页和预览页两侧的留白。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Toggle("实时预览（所见即所得）", isOn: Binding(get: { livePreviewEnabled }, set: { enabled in
                setLivePreviewEnabled(enabled)
            }))
            Text("开启后直接在正文中编辑标题、表格、代码块及折叠框；关闭后使用 Markdown 源码输入。⌘E 仍可切换阅读预览。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { showingShortcutSettings = true } label: { Label("快捷键设置…", systemImage: "keyboard") }
            HStack { Spacer(); Button("完成") { showingPreferences = false }.keyboardShortcut(.defaultAction) }
        }.padding(24)
        }.frame(width: 520, height: 660)
    }

    private func tabList(_ pane: AshDocumentPane) -> [EditorTab] {
        pane == .primary ? primaryTabs : secondaryTabs
    }

    private func selectedTabIndex(_ pane: AshDocumentPane) -> Int {
        pane == .primary ? primaryTabIndex : secondaryTabIndex
    }

    private func selectedTabID(_ pane: AshDocumentPane) -> UUID {
        let tabs = tabList(pane)
        return tabs[min(selectedTabIndex(pane), tabs.count - 1)].id
    }

    private func captureTab(_ pane: AshDocumentPane) -> EditorTab {
        var tab = tabList(pane)[min(selectedTabIndex(pane), tabList(pane).count - 1)]
        let secondary = pane == .secondary
        tab.title = secondary ? secondaryTitle : title
        tab.markdown = secondary ? secondaryMarkdown : markdown
        tab.fileURL = secondary ? secondaryFileURL : fileURL
        tab.sourceURL = secondary ? secondarySourceURL : primarySourceURL
        tab.saved = secondary ? savedSecondary : savedPrimary
        tab.storage = secondary ? secondaryStorage : primaryStorage
        tab.saveMode = secondary ? secondarySaveMode : saveMode
        return tab
    }

    private func tabRecords(_ pane: AshDocumentPane) -> [EditorTab] {
        var tabs = tabList(pane)
        tabs[min(selectedTabIndex(pane), tabs.count - 1)] = captureTab(pane)
        return tabs
    }

    private var dirtyTabs: [TabReference] {
        [AshDocumentPane.primary, .secondary].flatMap { pane in
            tabRecords(pane).filter(\.dirty).map { TabReference(id: $0.id, pane: pane) }
        }
    }

    private func cacheTab(_ pane: AshDocumentPane) {
        if pane == .primary { primaryTabs = tabRecords(pane) }
        else { secondaryTabs = tabRecords(pane) }
    }

    private func loadTab(_ tab: EditorTab, in pane: AshDocumentPane) {
        if pane == .primary {
            title = tab.title; markdown = tab.markdown
            fileURL = tab.fileURL; primarySourceURL = tab.sourceURL
            savedPrimary = tab.saved; primaryStorage = tab.storage; saveMode = tab.saveMode
            primaryFocusToken += 1
        } else {
            secondaryTitle = tab.title; secondaryMarkdown = tab.markdown
            secondaryFileURL = tab.fileURL; secondarySourceURL = tab.sourceURL
            savedSecondary = tab.saved; secondaryStorage = tab.storage; secondarySaveMode = tab.saveMode
            secondaryFocusToken += 1
        }
    }

    private func prepareNewTab(in pane: AshDocumentPane, reuseEmpty: Bool = true) {
        cacheTab(pane)
        let blank = EditorTab(placeholder: reuseEmpty)
        if reuseEmpty && captureTab(pane).isEmpty { return }
        if pane == .primary {
            primaryTabs.append(blank); primaryTabIndex = primaryTabs.count - 1
        } else {
            secondaryTabs.append(blank); secondaryTabIndex = secondaryTabs.count - 1
        }
        editorWindow?.makeFirstResponder(nil)
        loadTab(blank, in: pane)
    }

    private func activateTab(_ target: TabReference, completion: @escaping () -> Void = {}) {
        if chatMode { closeChatMode() }
        editorWindow?.makeFirstResponder(nil)
        activePane = target.pane
        LiveMarkdownEditors.flush(secondary: target.pane == .secondary) {
            guard let index = tabList(target.pane).firstIndex(where: { $0.id == target.id }) else { return }
            cacheTab(target.pane)
            if target.pane == .primary { primaryTabIndex = index } else { secondaryTabIndex = index }
            loadTab(tabList(target.pane)[index], in: target.pane)
            activePane = target.pane
            showingPreview = false
            completion()
        }
    }

    private func cycleTab(_ direction: Int) {
        let tabs = tabList(activePane)
        let index = (selectedTabIndex(activePane) + direction + tabs.count) % tabs.count
        activateTab(TabReference(id: tabs[index].id, pane: activePane))
    }

    private func requestCloseActiveTab() {
        if chatMode { closeChatMode(); return }
        requestCloseTab(TabReference(id: selectedTabID(activePane), pane: activePane))
    }

    private func requestCloseTab(_ target: TabReference) {
        if chatMode { closeChatMode() }
        LiveMarkdownEditors.flush {
            guard let tab = tabRecords(target.pane).first(where: { $0.id == target.id }) else { return }
            if tab.dirty {
                pendingTabClose = target; showingTabClosePrompt = true
            } else { removeTab(target) }
        }
    }

    private func removeTab(_ target: TabReference) {
        cacheTab(target.pane)
        var tabs = tabList(target.pane)
        guard let index = tabs.firstIndex(where: { $0.id == target.id }) else { return }
        let previousIndex = selectedTabIndex(target.pane)
        tabs.remove(at: index)
        if tabs.isEmpty { tabs = [EditorTab()] }
        let nextIndex = min(previousIndex > index ? previousIndex - 1 : previousIndex, tabs.count - 1)
        if target.pane == .primary { primaryTabs = tabs; primaryTabIndex = nextIndex }
        else { secondaryTabs = tabs; secondaryTabIndex = nextIndex }
        loadTab(tabs[nextIndex], in: target.pane)
    }

    private func moveTab(_ target: TabReference, layout: AshSplitMode) {
        if chatMode { closeChatMode() }
        LiveMarkdownEditors.flush {
            cacheTab(.primary); cacheTab(.secondary)
            guard let tab = tabList(target.pane).first(where: { $0.id == target.id }) else { return }
            let destination: AshDocumentPane = target.pane == .primary ? .secondary : .primary
            removeTab(target)
            var tabs = tabList(destination)
            if tabs.count == 1 && captureTab(destination).isEmpty && captureTab(destination).placeholder { tabs = [] }
            tabs.append(tab)
            if destination == .primary { primaryTabs = tabs; primaryTabIndex = tabs.count - 1 }
            else { secondaryTabs = tabs; secondaryTabIndex = tabs.count - 1 }
            loadTab(tab, in: destination)
            activePane = destination; splitModeRaw = layout.rawValue
            showingPreview = false
        }
    }

    private func setSplitLayout(_ layout: AshSplitMode) {
        if chatMode { closeChatMode() }
        LiveMarkdownEditors.flush {
            if layout == .off {
                let selected = selectedTabID(activePane)
                var tabs = tabRecords(.primary).filter { !($0.isEmpty && $0.placeholder) }
                tabs += tabRecords(.secondary).filter { !($0.isEmpty && $0.placeholder) }
                if tabs.isEmpty { tabs = [EditorTab()] }
                primaryTabs = tabs
                primaryTabIndex = tabs.firstIndex(where: { $0.id == selected }) ?? 0
                secondaryTabs = [EditorTab()]; secondaryTabIndex = 0
                loadTab(secondaryTabs[0], in: .secondary)
                loadTab(tabs[primaryTabIndex], in: .primary)
                activePane = .primary
            }
            splitModeRaw = layout.rawValue
        }
    }

    private func saveNextDirtyTabAndClose() {
        guard let target = dirtyTabs.first else {
            closeAfterSave = false
            if let reply = quitReply { quitReply = nil; reply(true); return }
            if let editorWindow { closeInterceptor.closeWithoutPrompt(editorWindow) }
            return
        }
        activateTab(target) { savePanel(forSecondary: target.pane == .secondary) }
    }

    private func moveDroppedTab(_ id: UUID, to destination: AshDocumentPane, before target: UUID?) -> Bool {
        guard id != target,
              [AshDocumentPane.primary, .secondary].contains(where: { tabList($0).contains(where: { $0.id == id }) }) else { return false }
        LiveMarkdownEditors.flush {
            cacheTab(.primary); cacheTab(.secondary)
            let source: AshDocumentPane = primaryTabs.contains(where: { $0.id == id }) ? .primary : .secondary
            var sourceTabs = tabList(source)
            guard let index = sourceTabs.firstIndex(where: { $0.id == id }) else { return }
            let sourceSelected = selectedTabID(source)
            let tab = sourceTabs.remove(at: index)
            var destinationTabs = source == destination ? sourceTabs : tabList(destination)
            if source != destination { destinationTabs.removeAll { $0.placeholder && $0.isEmpty } }
            let insertion = target.flatMap { targetID in destinationTabs.firstIndex(where: { $0.id == targetID }) } ?? destinationTabs.count
            destinationTabs.insert(tab, at: insertion)
            if source != destination {
                if sourceTabs.isEmpty { sourceTabs = [EditorTab()] }
                let selected = sourceTabs.firstIndex(where: { $0.id == sourceSelected }) ?? min(index, sourceTabs.count - 1)
                if source == .primary { primaryTabs = sourceTabs; primaryTabIndex = selected }
                else { secondaryTabs = sourceTabs; secondaryTabIndex = selected }
                loadTab(sourceTabs[selected], in: source)
            }
            if destination == .primary { primaryTabs = destinationTabs; primaryTabIndex = insertion }
            else { secondaryTabs = destinationTabs; secondaryTabIndex = insertion }
            loadTab(tab, in: destination)
            activePane = destination
        }
        return true
    }

    private func tabBar(_ pane: AshDocumentPane) -> some View {
        let items = tabRecords(pane).enumerated().map { index, tab in
            DocumentTabItem(id: tab.id, title: (privacy || fadingPrivacy) ? "文档" : (tab.sourceURL?.lastPathComponent ?? (tab.title.isEmpty ? "无标题笔记 \(index + 1)" : tab.title)),
                            dirty: tab.dirty, path: tab.sourceURL?.path)
        }
        return DocumentTabBar(items: items, selected: selectedTabID(pane), accent: purple, ink: fontColor,
                              select: { activateTab(TabReference(id: $0, pane: pane)) },
                              close: { requestCloseTab(TabReference(id: $0, pane: pane)) },
                              new: { activePane = pane; requestNewDocument() },
                              allowsWindowDrag: focusMode,
                              leadingInset: focusMode && pane == .primary ? CGFloat(76 / uiScale) : 0,
                              windowControlExclusion: focusMode && pane == .primary ? CGFloat(64 / uiScale) : 0,
                              moveRight: { moveTab(TabReference(id: $0, pane: pane), layout: .sideBySide) },
                              moveBelow: { moveTab(TabReference(id: $0, pane: pane), layout: .stacked) },
                              moveDroppedTab: { moveDroppedTab($0, to: pane, before: $1) },
                              openDroppedFile: { openDroppedFile($0, in: pane) })
            .frame(height: focusMode ? 43 : 34)
            .overlay(alignment: .top) {
                if splitMode != .off && activePane == pane { Rectangle().fill(purple.opacity(0.4)).frame(height: 1) }
            }
    }

    private func toggleChatMode() {
        if chatMode { closeChatMode(); return }
        LiveMarkdownEditors.flush { enterChatMode() }
    }
    private func enterChatMode() {
        guard let mainWindow = editorWindow else { return }
        let secondary = activePane == .secondary
        compactWindow.fading = fadingPrivacy
        compactWindow.fadeInitialOpacity = fadeInitialOpacity
        compactWindow.fadeDuration = fadeDuration
        showingPreview = false
        chatMode = true
        // Hide the document window before the auxiliary panel activates its IME.
        mainWindow.orderOut(nil)
        compactWindow.present(text: activeMarkdown, concealed: privacy, size: fontSize,
                              ink: fontColor, canvas: canvasColor, alignment: alignment,
                              edit: { value in
            if secondary { secondaryMarkdown = value } else { markdown = value }
        }, exit: { closeChatMode() })
    }

    private func cleanupEditor() {
        guard !chatMode else { return }
        ApplicationQuitGuard.shared.detach(id: terminationID)
        shortcuts.uninstall()
        compactWindow.dismiss()
    }

    private func closeChatMode() {
        guard chatMode else { return }
        chatMode = false
        compactWindow.dismiss()
        NSApp.activate(ignoringOtherApps: true)
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    private func toggleFocusMode() {
        if chatMode { closeChatMode(); focusMode = true } else { focusMode.toggle() }
    }

    private func toggleFadingPrivacy() {
        privacy = false
        fadingPrivacy.toggle()
        compactWindow.concealed = false
        compactWindow.fading = fadingPrivacy
        compactWindow.fadeInitialOpacity = fadeInitialOpacity
        compactWindow.fadeDuration = fadeDuration
        showingPreview = false
        status = fadingPrivacy ? "渐隐模式：新输入的文字将在数秒内淡出" : "正文内容已显示"
    }

    private func togglePrivacyMode() {
        fadingPrivacy = false
        compactWindow.fading = false
        privacy.toggle()
        compactWindow.concealed = privacy
        showingPreview = false
        status = privacy ? "正文内容已隐藏；输入内容仍会保存" : "正文内容已显示"
    }

    private func handleEditorCommand(_ command: String) {
        switch command {
        case "preview":
            LiveMarkdownEditors.flush { showingPreview.toggle() }
        case "privacy:fade": toggleFadingPrivacy()
        case "privacy": togglePrivacyMode()
        case "focus": toggleFocusMode()
        case "chat": toggleChatMode()
        case "chat:pin": compactWindow.togglePinned()
        case "split:sideBySide": setSplitLayout(.sideBySide)
        case "split:stacked": setSplitLayout(.stacked)
        case "split:off": setSplitLayout(.off)
        case "tab:close": requestCloseActiveTab()
        case "tab:next": cycleTab(1)
        case "tab:previous": cycleTab(-1)
        case "center": alignment = alignment == "center" ? "left" : "center"
        case "font:up": fontSize = min(32, fontSize + 1)
        case "font:down": fontSize = max(13, fontSize - 1)
        default: break
        }
    }

    private func exportMarkdown() {
        LiveMarkdownEditors.flush { beginExportMarkdown() }
    }
    private func beginExportMarkdown() {
        if chatMode { closeChatMode() }
        exportForSecondary = activePane == .secondary
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = markdownSuggestedFilename
        panel.canCreateDirectories = true
        guard let window = editorWindow ?? NSApp.keyWindow else { status = "无法取得主窗口"; return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try (exportForSecondary ? secondaryMarkdown : markdown).write(to: url, atomically: true, encoding: .utf8)
                status = "Markdown 已导出为 \(url.lastPathComponent)"
            } catch { errorMessage = error.localizedDescription; showingError = true }
        }
    }

    private var passwordSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(pendingOpen ? "解锁 ASH 文档" : "另存为", systemImage: "lock.shield.fill")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.ink)
            if !pendingOpen {
                Picker("文件格式", selection: $saveAsMarkdown) {
                    Text("ASH 加密文档 (.ash)").tag(false)
                    Text("Markdown 文档 (.md)").tag(true)
                }
            }
            if !pendingOpen && !saveAsMarkdown {
                Picker("加密方式", selection: $saveMode) {
                    ForEach(AshSaveMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.radioGroup)
            }
            Text(pendingOpen ? "输入创建文档时使用的密码。默认加密文档会自动解锁。" : (saveAsMarkdown ? "保存为普通 Markdown 文本，不加密。转换格式将创建独立文件。" : saveMode == .local ? "默认加密由应用自动使用内置密码，无需输入；个人密码模式可用于跨设备打开。" : "设置至少 8 个字符的个人密码。可在支持 ASH 格式的设备间使用同一密码。"))
                .font(.system(size: 12)).foregroundStyle(theme.muted).fixedSize(horizontal: false, vertical: true)
            if pendingOpen || (!saveAsMarkdown && saveMode == .personal) {
                SecureField("文档密码", text: $password).textFieldStyle(.roundedBorder)
                if !pendingOpen { SecureField("再次输入密码", text: $confirmPassword).textFieldStyle(.roundedBorder) }
            }
            HStack {
                Button("取消") {
                    showingPassword = false
                    password = ""
                    confirmPassword = ""
                    pendingOpen = false
                    pendingOpenURL = nil
                    closeAfterSave = false
                    closeTabAfterSaving = nil
                    cancelQuitRequest()
                    cancelPendingDocumentOpen()
                }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(pendingOpen ? "解锁" : "选择保存位置…") { acceptPassword() }
                    .buttonStyle(AshPrimaryButton(color: purple)).disabled(!pendingOpen && !saveAsMarkdown && saveMode == .personal && (password.count < 8 || password != confirmPassword))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 390)
    }

    private func openPanel(forSecondary: Bool = false, authorizationURL: URL? = nil) {
        if chatMode { closeChatMode() }
        pendingSecondary = forSecondary
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ash") ?? .data, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let authorizationURL {
            panel.title = "为最近文档重新授权"
            panel.prompt = "授权并打开"
            panel.directoryURL = authorizationURL.deletingLastPathComponent()
            panel.nameFieldStringValue = authorizationURL.lastPathComponent
        }
        guard let window = editorWindow ?? NSApp.keyWindow else { status = "无法取得主窗口"; return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            requestOpenDocument(url, toSecondary: forSecondary)
        }
    }

    private func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "打开工作文件夹"
        panel.prompt = "打开文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderWorkspace.rootURL
        guard let window = editorWindow ?? NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try folderWorkspace.open(url)
                folderExpanded = true
                status = "已打开文件夹：\(url.lastPathComponent)"
            } catch {
                errorMessage = "无法打开文件夹：\(error.localizedDescription)"
                showingError = true
            }
        }
    }

    private func openSidebarDocument(_ url: URL) {
        requestOpenDocument(url, toSecondary: activePane == .secondary)
    }

    private func openDroppedFile(_ url: URL, in destination: AshDocumentPane) {
        let standardizedURL = url.standardizedFileURL
        for source in [AshDocumentPane.primary, .secondary] {
            if let tab = tabRecords(source).first(where: {
                $0.sourceURL?.standardizedFileURL == standardizedURL
            }) {
                let reference = TabReference(id: tab.id, pane: source)
                if source == destination {
                    activateTab(reference)
                } else {
                    _ = moveDroppedTab(tab.id, to: destination, before: nil)
                }
                return
            }
        }
        requestOpenDocument(standardizedURL, toSecondary: destination == .secondary)
    }

    private func requestOpenDocument(_ url: URL, toSecondary: Bool) {
        let preferred: AshDocumentPane = toSecondary ? .secondary : .primary
        for pane in [preferred, preferred == .primary ? .secondary : .primary] {
            if let existing = tabRecords(pane).first(where: { $0.sourceURL?.standardizedFileURL == url.standardizedFileURL }) {
                activateTab(TabReference(id: existing.id, pane: pane))
                return
            }
        }
        requestDocumentNavigation(PendingDocumentOpen(url: url, secondary: toSecondary))
    }

    private func requestNewDocument() {
        if chatMode { closeChatMode() }
        requestDocumentNavigation(PendingDocumentOpen(url: nil, secondary: activePane == .secondary))
    }

    private func requestDocumentNavigation(_ request: PendingDocumentOpen) {
        LiveMarkdownEditors.flush { beginDocumentNavigation(request) }
    }
    private func beginDocumentNavigation(_ request: PendingDocumentOpen) {
        // Opening a document no longer replaces an unsaved buffer: it gets a tab.
        performOpenDocument(request)
    }

    private func performOpenDocument(_ request: PendingDocumentOpen) {
        guard let url = request.url else {
            prepareNewTab(in: request.secondary ? .secondary : .primary, reuseEmpty: false)
            if request.secondary {
                secondaryTitle = ""; secondaryMarkdown = ""; secondaryFileURL = nil; secondarySourceURL = nil
                savedSecondary = EditorContentSnapshot(); secondarySaveMode = .local; secondaryStorage = .defaultEncrypted
                secondaryFocusToken += 1
            } else {
                title = ""; markdown = ""; fileURL = nil; primarySourceURL = nil
                savedPrimary = EditorContentSnapshot(); saveMode = .local; primaryStorage = .defaultEncrypted
                primaryFocusToken += 1
            }
            activePane = request.secondary ? .secondary : .primary
            pendingOpenURL = nil; pendingOpen = false; showingPreview = false
            status = "新文档 · 尚未保存"
            return
        }
        if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            openMarkdownDocument(at: url, toSecondary: request.secondary)
        } else {
            openAshDocument(at: url, toSecondary: request.secondary)
        }
    }

    private func cancelPendingDocumentOpen() {
        pendingDocumentOpen = nil
        saveBeforeOpening = false
    }

    private func openDocumentAfterSaving() {
        guard saveBeforeOpening, let request = pendingDocumentOpen else { return }
        cancelPendingDocumentOpen()
        // A password/save sheet may still be dismissing at this point.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { performOpenDocument(request) }
    }

    private func revealDocument(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func removeRecentDocument(_ url: URL) {
        do {
            try recentIndex.remove(url)
            status = "已移除最近文档记录，文件仍保留在磁盘上"
        } catch {
            errorMessage = "无法更新最近文档索引：\(error.localizedDescription)"
            showingError = true
        }
    }

    private func confirmTrash(_ url: URL) {
        pendingTrashURL = url
        showingTrashConfirmation = true
    }

    private func trashDocument(_ url: URL) {
        do {
            try withFileAccess(url) { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
            removeRecentDocument(url)
            for pane in [AshDocumentPane.primary, .secondary] {
                let tabs = tabRecords(pane).map { original in
                    var tab = original
                    if tab.sourceURL?.standardizedFileURL == url.standardizedFileURL {
                        tab.sourceURL = nil; tab.fileURL = nil; tab.saved = EditorContentSnapshot()
                    }
                    return tab
                }
                if pane == .primary { primaryTabs = tabs } else { secondaryTabs = tabs }
                loadTab(tabs[selectedTabIndex(pane)], in: pane)
            }
            folderWorkspace.refresh()
            status = "文件已移到废纸篓；已打开的编辑内容仍可另存"
        } catch {
            errorMessage = "无法将文件移到废纸篓：\(error.localizedDescription)"
            showingError = true
        }
    }

    private func openMarkdownDocument(at url: URL, toSecondary: Bool) {
        do {
            let text = try withFileAccess(url) { try String(contentsOf: $0, encoding: .utf8) }
            let importedTitle = url.deletingPathExtension().lastPathComponent
            let snapshot = EditorContentSnapshot(title: importedTitle, markdown: text)
            prepareNewTab(in: toSecondary ? .secondary : .primary)
            if toSecondary {
                secondaryTitle = importedTitle; secondaryMarkdown = text
                secondarySourceURL = url; secondaryFileURL = url
                savedSecondary = snapshot; secondaryStorage = .markdown
            } else {
                title = importedTitle; markdown = text
                primarySourceURL = url; fileURL = url
                savedPrimary = snapshot; primaryStorage = .markdown
            }
            activePane = toSecondary ? .secondary : .primary
            showingPreview = false
            status = "已打开 Markdown；⌘S 保存原文件，另存为可转换格式"
            remember(url)
        } catch { errorMessage = error.localizedDescription; showingError = true }
    }

    /// Save preserves format and credentials; a changed title renames the file in its current folder.
    private func savePanel(forSecondary: Bool = false) {
        LiveMarkdownEditors.flush(secondary: forSecondary) { saveCurrentDocument(forSecondary: forSecondary) }
    }
    private func saveCurrentDocument(forSecondary: Bool) {
        let target = forSecondary ? secondaryFileURL : fileURL
        guard let target else { saveAsPanel(forSecondary: forSecondary); return }
        let storage = forSecondary ? secondaryStorage : primaryStorage
        do {
            var document = makeDocument(forSecondary: forSecondary)
            let destination = try DocumentStorage.synchronizedURL(title: forSecondary ? secondaryTitle : title, source: target)
            document.title = destination.deletingPathExtension().lastPathComponent
            let prepared = try ASHImageAssets.prepareForSave(markdown: document.markdown, destination: destination,
                workspaceRoot: folderWorkspace.rootURL, storage: storage, sourceURL: target, sourceStorage: storage,
                readData: { assetURL in try withFileAccess(assetURL) { try Data(contentsOf: $0) } })
            document.markdown = prepared.markdown
            let snapshot = EditorContentSnapshot(title: document.title, markdown: document.markdown)
            let data = try storage.encode(document)
            let savedURL = try withFileAccess(target) {
                try DocumentStorage.save(data, to: $0, renamingTo: destination)
            }
            prepared.finishAfterDocumentSave()
            if savedURL.standardizedFileURL != target.standardizedFileURL { try? recentIndex.remove(target) }
            finishSaving(savedURL, storage: storage, snapshot: snapshot, secondary: forSecondary)
        } catch { saveFailed(error) }
    }

    private func saveAsPanel(forSecondary: Bool = false) {
        LiveMarkdownEditors.flush(secondary: forSecondary) { beginSaveAs(forSecondary: forSecondary) }
    }
    private func beginSaveAs(forSecondary: Bool) {
        if chatMode { closeChatMode() }
        pendingSecondary = forSecondary
        pendingOpen = false
        password = ""; confirmPassword = ""
        let current = forSecondary ? secondaryStorage : primaryStorage
        saveAsMarkdown = current.isMarkdown
        if case .personalEncrypted = current { saveMode = .personal } else { saveMode = .local }
        showingPassword = true
    }

    private var unsavedPromptOverlay: some View {
        ZStack {
            Color.black.opacity(0.26).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 13) {
                Text("要保存 \(dirtyTabs.count) 个标签页的修改吗？")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(theme.ink)
                Text("你可以依次保存这些标签页，或者丢弃所有未保存的修改后退出。")
                    .font(.system(size: 13)).foregroundStyle(theme.muted)
                HStack {
                    Button("不保存") { discardAndClose() }
                    Spacer()
                    Button("取消") { showingUnsavedPrompt = false; cancelQuitRequest() }
                    Button("全部保存") { showingUnsavedPrompt = false; closeAfterSave = true; saveNextDirtyTabAndClose() }
                        .buttonStyle(AshPrimaryButton(color: purple))
                }.padding(.top, 5)
            }
            .padding(24).frame(width: 470)
            .background(theme.paper, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.18), radius: 28, y: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(10)
    }

    private func discardAndClose() {
        showingUnsavedPrompt = false
        if let reply = quitReply { quitReply = nil; reply(true); return }
        if let editorWindow {
            // Clear this scene before closing. SwiftUI can retain a closed
            // WindowGroup scene, which would otherwise restore the discarded draft.
            discardWindowContents()
            cleanupEditor()
            closeInterceptor.closeWithoutPrompt(editorWindow)
        }
    }

    private func discardWindowContents() {
        title = ""; markdown = ""; fileURL = nil; primarySourceURL = nil
        savedPrimary = EditorContentSnapshot(); primaryStorage = .defaultEncrypted; saveMode = .local
        secondaryTitle = ""; secondaryMarkdown = ""; secondaryFileURL = nil; secondarySourceURL = nil
        savedSecondary = EditorContentSnapshot(); secondaryStorage = .defaultEncrypted; secondarySaveMode = .local
        primaryTabs = [EditorTab()]; secondaryTabs = [EditorTab()]
        primaryTabIndex = 0; secondaryTabIndex = 0; activePane = .primary
        pendingDocumentOpen = nil; pendingOpenURL = nil; showingDocumentSwitchPrompt = false
        pendingTabClose = nil; closeTabAfterSaving = nil; showingTabClosePrompt = false
        showingPreview = false; closeAfterSave = false
        primaryFocusToken += 1; secondaryFocusToken += 1
        status = "新文档 · 尚未保存"
    }

    private func cancelQuitRequest() {
        if let reply = quitReply { quitReply = nil; reply(false) }
    }

    private func ashBaseName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.lowercased().hasSuffix(".ash") ? String(trimmed.dropLast(4)) : trimmed
        return base.isEmpty ? "未命名" : base
    }

    private func openRecent(_ url: URL) {
        // If it is already open, switching to its tab needs no new file grant.
        for pane in [AshDocumentPane.primary, .secondary] {
            if let tab = tabRecords(pane).first(where: {
                guard let sourceURL = $0.sourceURL else { return false }
                return sameDocumentPath(sourceURL, url)
            }) {
                activateTab(TabReference(id: tab.id, pane: pane))
                return
            }
        }

        guard recentIndex.hasBookmark(for: url) || folderWorkspace.authorizes(url) else {
            status = "旧版最近文档需要重新授权，请在系统窗口中选择该文件一次"
            openPanel(forSecondary: activePane == .secondary, authorizationURL: url)
            return
        }
        openSidebarDocument(recentIndex.accessURL(for: url))
    }

    private func sameDocumentPath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path ==
            rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func openAshDocument(at url: URL, toSecondary: Bool) {
        pendingOpen = false
        do {
            let data = try withFileAccess(url) { try Data(contentsOf: $0) }
            let document: AshDocument
            let storage: DocumentStorage
            if AshFile.isLocal(data) {
                document = try AshFile.openLocal(data)
                storage = .legacyLocal
                status = "本机加密文档已解锁"
            } else if AshFile.isDefault(data) {
                document = try AshFile.openDefault(data)
                storage = .defaultEncrypted
                status = "默认加密文档已自动解锁"
            } else if let legacyDefaultDocument = try? AshFile.open(data, password: "") {
                // Older local-save builds wrote ASH1 using an empty password.
                document = legacyDefaultDocument
                storage = .personalEncrypted("")
                status = "旧版默认加密文档已解锁；建议重新加密保存"
            } else {
                pendingOpen = true
                pendingSecondary = toSecondary
                pendingOpenURL = url
                password = ""
                showingPassword = true
                return
            }
            prepareNewTab(in: toSecondary ? .secondary : .primary)
            setStorage(storage, secondary: toSecondary)
            apply(document, toSecondary: toSecondary)
            attachOpenedFile(url, toSecondary: toSecondary)
            remember(url)
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
        }
    }

    private func attachOpenedFile(_ url: URL, toSecondary: Bool) {
        let filenameTitle = url.deletingPathExtension().lastPathComponent
        if toSecondary {
            secondaryTitle = filenameTitle
            savedSecondary.title = filenameTitle
        } else {
            title = filenameTitle
            savedPrimary.title = filenameTitle
        }
        if toSecondary {
            secondaryFileURL = url
            secondarySourceURL = url
        } else {
            fileURL = url
            primarySourceURL = url
        }
        activePane = toSecondary ? .secondary : .primary
        pendingOpenURL = nil
        pendingOpen = false
    }

    private func remember(_ url: URL) {
        do {
            try recentIndex.remember(url)
        } catch {
            status = "最近文档索引更新失败：\(error.localizedDescription)"
        }
    }

    private func withFileAccess<T>(_ url: URL, _ operation: (URL) throws -> T) throws -> T {
        let granted = recentIndex.accessURL(for: url)
        let didStart = granted.startAccessingSecurityScopedResource()
        defer { if didStart { granted.stopAccessingSecurityScopedResource() } }
        return try operation(granted)
    }

    private func apply(_ document: AshDocument, toSecondary: Bool = false) {
        // Night mode is an app-wide viewing preference: opening an older document
        // must not unexpectedly switch the editor back to its stored light palette.
        let keepNightTheme = theme == .night
        let documentTheme = AshTheme.allCases.first { $0.rawValue == document.theme } ?? .purple
        if toSecondary {
            secondaryTitle = document.title
            secondaryMarkdown = document.markdown
            savedSecondary = EditorContentSnapshot(title: document.title, markdown: document.markdown)
        } else {
            title = document.title
            markdown = document.markdown
            savedPrimary = EditorContentSnapshot(title: document.title, markdown: document.markdown)
        }
        fontSize = Double(document.fontSize)
        alignment = document.alignment
        if !keepNightTheme { theme = documentTheme }
        canvasColor = keepNightTheme ? AshTheme.night.background : (document.backgroundHex.flatMap(Color.init(hex:)) ?? theme.background)
        fontColor = keepNightTheme ? AshTheme.night.ink : (document.fontHex.flatMap(Color.init(hex:)) ?? theme.ink)
    }

    private func makeDocument(forSecondary: Bool = false) -> AshDocument {
        let documentTitle = forSecondary ? secondaryTitle : title
        let documentMarkdown = forSecondary ? secondaryMarkdown : markdown
        return AshDocument(title: documentTitle.isEmpty ? "未命名" : documentTitle, markdown: documentMarkdown,
                    fontSize: Int(fontSize), alignment: alignment, theme: theme.rawValue,
                    backgroundHex: canvasColor.hexString, fontHex: fontColor.hexString)
    }

    private func setStorage(_ storage: DocumentStorage, secondary: Bool) {
        let mode: AshSaveMode
        if case .personalEncrypted = storage { mode = .personal } else { mode = .local }
        if secondary { secondaryStorage = storage; secondarySaveMode = mode }
        else { primaryStorage = storage; saveMode = mode }
    }

    private func presentSaveAs(storage: DocumentStorage, secondary: Bool) {
        let document = makeDocument(forSecondary: secondary)
        let source = secondary ? secondaryFileURL : fileURL
        let panel = NSSavePanel()
        panel.title = "另存为"
        panel.allowedContentTypes = [UTType(filenameExtension: storage.isMarkdown ? "md" : "ash") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = DocumentStorage.suggestedName(title: document.title, source: source, markdown: storage.isMarkdown)
        // A directory derived from a security-scoped FILE URL inherits that file's scope.
        // Give the system panel a fresh directory URL so it can grant access to a sibling file.
        if let directory = source?.deletingLastPathComponent() ?? folderWorkspace.rootURL {
            panel.directoryURL = URL(fileURLWithPath: directory.path, isDirectory: true)
        }
        panel.canCreateDirectories = true
        guard let window = editorWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else {
                closeAfterSave = false; cancelPendingDocumentOpen()
                closeTabAfterSaving = nil
                cancelQuitRequest()
                status = "已取消另存为"
                return
            }
            do {
                // Never overwrite the source MD with encrypted bytes, even for an unexpected panel URL.
                if !storage.isMarkdown, let source, ["md", "markdown"].contains(source.pathExtension.lowercased()),
                   source.standardizedFileURL == url.standardizedFileURL {
                    throw NSError(domain: "ASH.Save", code: 1, userInfo: [NSLocalizedDescriptionKey: "请为 ASH 文件使用独立的 .ash 文件名，原 Markdown 文件会保留。"])
                }
                var savedDocument = document
                savedDocument.title = url.deletingPathExtension().lastPathComponent
                let sourceURL = secondary ? secondaryFileURL : fileURL
                let sourceStorage = secondary ? secondaryStorage : primaryStorage
                let prepared = try ASHImageAssets.prepareForSave(markdown: savedDocument.markdown, destination: url,
                    workspaceRoot: folderWorkspace.rootURL, storage: storage, sourceURL: sourceURL, sourceStorage: sourceStorage,
                    readData: { assetURL in try withFileAccess(assetURL) { try Data(contentsOf: $0) } })
                savedDocument.markdown = prepared.markdown
                let snapshot = EditorContentSnapshot(title: savedDocument.title, markdown: savedDocument.markdown)
                let data = try storage.encode(savedDocument)
                try withFileAccess(url) { try data.write(to: $0, options: .atomic) }
                prepared.finishAfterDocumentSave()
                finishSaving(url, storage: storage, snapshot: snapshot, secondary: secondary)
            } catch { saveFailed(error) }
        }
    }

    private func finishSaving(_ url: URL, storage: DocumentStorage, snapshot: EditorContentSnapshot, secondary: Bool) {
        attachOpenedFile(url, toSecondary: secondary)
        setStorage(storage, secondary: secondary)
        if secondary { secondaryMarkdown = snapshot.markdown; savedSecondary = snapshot }
        else { markdown = snapshot.markdown; savedPrimary = snapshot }
        remember(url)
        status = "已保存：\(url.lastPathComponent)"
        folderWorkspace.refresh()
        openDocumentAfterSaving()
        if let target = closeTabAfterSaving {
            closeTabAfterSaving = nil; pendingTabClose = nil
            removeTab(target)
        }
        if closeAfterSave {
            saveNextDirtyTabAndClose()
        }
    }

    private func saveFailed(_ error: Error) {
        closeTabAfterSaving = nil
        cancelQuitRequest()
        closeAfterSave = false; cancelPendingDocumentOpen()
        if chatMode { closeChatMode() }
        errorMessage = error.localizedDescription; showingError = true
    }

    private func acceptPassword() {
        let entered = password; password = ""; confirmPassword = ""; showingPassword = false
        if pendingOpen {
            do {
                guard let targetURL = pendingOpenURL else { return }
                let data = try withFileAccess(targetURL) { try Data(contentsOf: $0) }
                guard !AshFile.isLocal(data) && !AshFile.isDefault(data) else {
                    let document = try AshFile.isDefault(data) ? AshFile.openDefault(data) : AshFile.openLocal(data)
                    prepareNewTab(in: pendingSecondary ? .secondary : .primary)
                    setStorage(AshFile.isDefault(data) ? .defaultEncrypted : .legacyLocal, secondary: pendingSecondary)
                    apply(document, toSecondary: pendingSecondary)
                    attachOpenedFile(targetURL, toSecondary: pendingSecondary)
                    remember(targetURL)
                    if pendingSecondary { secondarySaveMode = .local } else { saveMode = .local }
                    return
                }
                let document = try AshFile.open(data, password: entered)
                prepareNewTab(in: pendingSecondary ? .secondary : .primary)
                setStorage(.personalEncrypted(entered), secondary: pendingSecondary)
                apply(document, toSecondary: pendingSecondary)
                attachOpenedFile(targetURL, toSecondary: pendingSecondary)
                if pendingSecondary { secondarySaveMode = .personal } else { saveMode = .personal }
                remember(targetURL)
                status = "文档已解锁"
            } catch { errorMessage = error.localizedDescription; showingError = true }
        } else {
            let storage: DocumentStorage = saveAsMarkdown ? .markdown : (saveMode == .personal ? .personalEncrypted(entered) : .defaultEncrypted)
            let secondary = pendingSecondary
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                presentSaveAs(storage: storage, secondary: secondary)
            }
        }
    }

}

private struct MarkdownPreview: View {
    let markdown: String
    let color: Color
    let background: Color
    let size: Double
    let alignment: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                if case let .details(summary, content) = block {
                    DisclosureGroup {
                        MarkdownLines(markdown: content, color: color, background: background, size: size, alignment: alignment)
                            .padding(.top, 7)
                    } label: {
                        Text(summary).font(.system(size: size, weight: .medium, design: .serif)).foregroundStyle(color)
                    }
                    .tint(color.opacity(0.7))
                    .padding(12)
                    .background(background, in: RoundedRectangle(cornerRadius: 9))
                } else if case let .text(text) = block {
                    MarkdownLines(markdown: text, color: color, background: background, size: size, alignment: alignment)
                }
            }
        }
    }

    private enum PreviewBlock {
        case text(String)
        case details(String, String)
    }

    private var blocks: [PreviewBlock] {
        let pattern = #"(?is)<details\b[^>]*>(.*?)</details\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [.text(markdown)] }
        let source = markdown as NSString
        let matches = regex.matches(in: markdown, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return [.text(markdown)] }
        var result: [PreviewBlock] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let text = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(text)) }
            }
            let inner = source.substring(with: match.range(at: 1))
            let summaryPattern = #"(?is)<summary\b[^>]*>(.*?)</summary\s*>"#
            if let summaryRegex = try? NSRegularExpression(pattern: summaryPattern),
               let summaryMatch = summaryRegex.firstMatch(in: inner, range: NSRange(location: 0, length: (inner as NSString).length)) {
                let innerSource = inner as NSString
                let summary = innerSource.substring(with: summaryMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let body = innerSource.replacingCharacters(in: summaryMatch.range, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                result.append(.details(summary.isEmpty ? "详细内容" : summary, body))
            } else {
                result.append(.details("详细内容", inner.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            let text = source.substring(from: cursor)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.text(text)) }
        }
        return result
    }
}

private struct MarkdownLines: View {
    let markdown: String
    let color: Color
    let background: Color
    let size: Double
    let alignment: String
    var body: some View {
        Markdown(markdown)
            .markdownTheme(.gitHub)
            .markdownTextStyle(\.text) {
                ForegroundColor(color)
                BackgroundColor(nil)
                FontSize(size)
            }
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                ForegroundColor(color)
                BackgroundColor(background.opacity(0.72))
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .markdownTextStyle {
                            FontFamilyVariant(.monospaced)
                            FontSize(.em(0.85))
                            ForegroundColor(color)
                        }
                        .padding(16)
                }
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .markdownMargin(top: 0, bottom: 16)
            }
            .font(.system(size: size, design: .serif))
            .foregroundStyle(color)
            .multilineTextAlignment(alignment == "center" ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: alignment == "center" ? .center : .leading)
    }
}

private struct AshToolbarButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).foregroundStyle(Color.primary.opacity(0.72))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EditorWindowCloseHook: NSViewRepresentable {
    let interceptor: UnsavedCloseInterceptor
    let onAttach: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { if let window = view.window { onAttach(window) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { if let window = view.window { onAttach(window) } }
    }
}

@MainActor
private final class UnsavedCloseInterceptor: NSObject, NSWindowDelegate {
    private weak var previousDelegate: NSWindowDelegate?
    private var hasChanges: () -> Bool = { false }
    private var showPrompt: () -> Void = {}
    private var didClose: () -> Void = {}
    private var allowNextClose = false

    func attach(to window: NSWindow, hasUnsavedChanges: @escaping () -> Bool,
                prompt: @escaping () -> Void, didClose: @escaping () -> Void) {
        hasChanges = hasUnsavedChanges
        showPrompt = prompt
        self.didClose = didClose
        guard window.delegate !== self else { return }
        previousDelegate = window.delegate
        window.delegate = self
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowNextClose {
            allowNextClose = false
            return true
        }
        if previousDelegate?.windowShouldClose?(sender) == false { return false }
        guard hasChanges() else { return true }
        showPrompt()
        return false
    }

    func closeWithoutPrompt(_ window: NSWindow) {
        allowNextClose = true
        window.performClose(nil)
    }

    // NSWindow registers notification selectors when the delegate is attached.
    // A weak forwarded delegate may disappear before a later notification.
    // Keep these selectors implemented on the interceptor for its full lifetime.
    func windowDidResize(_ notification: Notification) {
        previousDelegate?.windowDidResize?(notification)
    }

    func windowDidExpose(_ notification: Notification) {
        previousDelegate?.windowDidExpose?(notification)
    }

    func windowWillMove(_ notification: Notification) {
        previousDelegate?.windowWillMove?(notification)
    }

    func windowDidMove(_ notification: Notification) {
        previousDelegate?.windowDidMove?(notification)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        previousDelegate?.windowDidBecomeKey?(notification)
    }

    func windowDidResignKey(_ notification: Notification) {
        previousDelegate?.windowDidResignKey?(notification)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        previousDelegate?.windowDidBecomeMain?(notification)
    }

    func windowDidResignMain(_ notification: Notification) {
        previousDelegate?.windowDidResignMain?(notification)
    }

    func windowWillClose(_ notification: Notification) {
        didClose()
        previousDelegate?.windowWillClose?(notification)
    }

    func windowWillMiniaturize(_ notification: Notification) {
        previousDelegate?.windowWillMiniaturize?(notification)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        previousDelegate?.windowDidMiniaturize?(notification)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        previousDelegate?.windowDidDeminiaturize?(notification)
    }

    func windowDidUpdate(_ notification: Notification) {
        previousDelegate?.windowDidUpdate?(notification)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        previousDelegate?.windowDidChangeScreen?(notification)
    }

    func windowDidChangeScreenProfile(_ notification: Notification) {
        previousDelegate?.windowDidChangeScreenProfile?(notification)
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        previousDelegate?.windowDidChangeBackingProperties?(notification)
    }

    func windowWillBeginSheet(_ notification: Notification) {
        previousDelegate?.windowWillBeginSheet?(notification)
    }

    func windowDidEndSheet(_ notification: Notification) {
        previousDelegate?.windowDidEndSheet?(notification)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        previousDelegate?.windowWillStartLiveResize?(notification)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        previousDelegate?.windowDidEndLiveResize?(notification)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        previousDelegate?.windowWillEnterFullScreen?(notification)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        previousDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        previousDelegate?.windowWillExitFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        previousDelegate?.windowDidExitFullScreen?(notification)
    }

    func windowWillEnterVersionBrowser(_ notification: Notification) {
        previousDelegate?.windowWillEnterVersionBrowser?(notification)
    }

    func windowDidEnterVersionBrowser(_ notification: Notification) {
        previousDelegate?.windowDidEnterVersionBrowser?(notification)
    }

    func windowWillExitVersionBrowser(_ notification: Notification) {
        previousDelegate?.windowWillExitVersionBrowser?(notification)
    }

    func windowDidExitVersionBrowser(_ notification: Notification) {
        previousDelegate?.windowDidExitVersionBrowser?(notification)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        previousDelegate?.windowDidChangeOcclusionState?(notification)
    }

    // Do not advertise selectors belonging to another object. AppKit also
    // queries private notification selectors; caching a forwarded capability
    // outlives the weak delegate and leads to unrecognized-selector crashes.
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        previousDelegate?.windowWillReturnFieldEditor?(sender, to: client)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        previousDelegate?.windowWillResize?(sender, to: frameSize) ?? frameSize
    }

    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame newFrame: NSRect) -> NSRect {
        previousDelegate?.windowWillUseStandardFrame?(window, defaultFrame: newFrame) ?? newFrame
    }

    func windowShouldZoom(_ window: NSWindow, toFrame newFrame: NSRect) -> Bool {
        previousDelegate?.windowShouldZoom?(window, toFrame: newFrame) ?? true
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        previousDelegate?.windowWillReturnUndoManager?(window)
    }

}

private struct AshPrimaryButton: ButtonStyle {
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(color.opacity(configuration.isPressed ? 0.76 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}
private extension Color {
    init?(hex: String) {
        let normalized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard normalized.count == 6, let value = UInt32(normalized, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255, opacity: 1)
    }
    var hexString: String {
        let color = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.black
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
