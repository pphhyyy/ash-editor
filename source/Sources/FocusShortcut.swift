import AppKit
import SwiftUI

enum AshShortcutAction: String, CaseIterable, Identifiable {
    case newDocument, open, save, saveAs, exportMarkdown, preview, livePreview, splitLeftRight, splitTopBottom, singleDocument
    case center, fadingPrivacy, privacy, focus, chat, pinChat, fontUp, fontDown
    case newTab, closeTab, nextTab, previousTab
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newDocument: "新建笔记"
        case .newTab: "新建标签页"
        case .closeTab: "关闭当前标签页"
        case .nextTab: "下一个标签页"
        case .previousTab: "上一个标签页"
        case .open: "打开文档"
        case .save: "保存"
        case .saveAs: "另存为"
        case .exportMarkdown: "导出 Markdown"
        case .preview: "预览 / 普通输入"
        case .livePreview: "实时预览（所见即所得）"
        case .splitLeftRight: "左右双文档"
        case .splitTopBottom: "上下双文档"
        case .singleDocument: "单文档模式"
        case .center: "居中模式"
        case .fadingPrivacy: "渐隐 / 显示正文"
        case .privacy: "隐藏 / 显示正文"
        case .focus: "普通 / 纯净模式"
        case .chat: "聊天框模式"
        case .pinChat: "聊天框置顶"
        case .fontUp: "增大字号"
        case .fontDown: "减小字号"
        }
    }
    var defaultBinding: ShortcutBinding? {
        switch self {
        case .newDocument: ShortcutBinding(keyCode: 45, modifiers: [.command], keyName: "N")
        case .newTab: ShortcutBinding(keyCode: 17, modifiers: [.command], keyName: "T")
        case .closeTab: ShortcutBinding(keyCode: 13, modifiers: [.command], keyName: "W")
        case .nextTab: ShortcutBinding(keyCode: 48, modifiers: [.control], keyName: "Tab")
        case .previousTab: ShortcutBinding(keyCode: 48, modifiers: [.control, .shift], keyName: "Tab")
        case .open: ShortcutBinding(keyCode: 31, modifiers: [.command], keyName: "O")
        case .save: ShortcutBinding(keyCode: 1, modifiers: [.command], keyName: "S")
        case .saveAs: ShortcutBinding(keyCode: 1, modifiers: [.command, .shift], keyName: "S")
        case .exportMarkdown: ShortcutBinding(keyCode: 14, modifiers: [.command, .shift], keyName: "E")
        case .preview: ShortcutBinding(keyCode: 14, modifiers: [.command], keyName: "E")
        case .livePreview: ShortcutBinding(keyCode: 14, modifiers: [.control, .shift], keyName: "E")
        case .splitLeftRight: ShortcutBinding(keyCode: 18, modifiers: [.command, .option], keyName: "1")
        case .splitTopBottom: ShortcutBinding(keyCode: 19, modifiers: [.command, .option], keyName: "2")
        case .singleDocument: ShortcutBinding(keyCode: 29, modifiers: [.command, .option], keyName: "0")
        case .center: ShortcutBinding(keyCode: 8, modifiers: [.command, .shift], keyName: "C")
        case .fadingPrivacy: ShortcutBinding(keyCode: 35, modifiers: [.control, .option], keyName: "P")
        case .privacy: ShortcutBinding(keyCode: 35, modifiers: [.control], keyName: "P")
        case .focus: ShortcutBinding(keyCode: 4, modifiers: [.control], keyName: "H")
        case .chat: ShortcutBinding(keyCode: 4, modifiers: [.control, .shift], keyName: "H")
        case .pinChat: ShortcutBinding(keyCode: 35, modifiers: [.control, .shift], keyName: "P")
        case .fontUp: ShortcutBinding(keyCode: 24, modifiers: [.command], keyName: "+")
        case .fontDown: ShortcutBinding(keyCode: 27, modifiers: [.command], keyName: "−")
        }
    }
}

struct ShortcutBinding: Equatable {
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags
    var keyName: String
    var display: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(keyName)
        return parts.joined(separator: " + ")
    }
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.control, .command, .shift, .option])
        guard !modifiers.isEmpty, let keyName = Self.name(for: event) else { return nil }
        self.init(keyCode: event.keyCode, modifiers: modifiers, keyName: keyName)
    }
    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }
    func matches(_ event: NSEvent) -> Bool {
        event.keyCode == keyCode && event.modifierFlags.intersection([.control, .command, .shift, .option]) == modifiers
    }
    static func == (lhs: ShortcutBinding, rhs: ShortcutBinding) -> Bool {
        lhs.keyCode == rhs.keyCode && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }
    private static func name(for event: NSEvent) -> String? {
        if event.keyCode == 36 { return "Return" }
        if event.keyCode == 48 { return "Tab" }
        if event.keyCode == 49 { return "Space" }
        if event.keyCode == 51 { return "Delete" }
        if event.keyCode == 53 { return "Esc" }
        guard let chars = event.charactersIgnoringModifiers?.uppercased(), chars.count == 1 else { return nil }
        return chars
    }
}

@MainActor
final class FocusShortcutController: ObservableObject {
    @Published private(set) var bindings: [AshShortcutAction: ShortcutBinding] = [:]
    @Published var recordingAction: AshShortcutAction?
    @Published var message: String?
    private var monitor: Any?
    private var perform: ((AshShortcutAction) -> Void)?

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: "ash.shortcutBindings") as? [String: [String: Any]] ?? [:]
        for action in AshShortcutAction.allCases {
            if let item = saved[action.rawValue], let keyCodeValue = item["keyCode"] as? Int,
               let rawModifiers = item["modifiers"] as? UInt, let keyName = item["keyName"] as? String {
                let keyCode = UInt16(keyCodeValue)
                bindings[action] = ShortcutBinding(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: rawModifiers), keyName: keyName)
            } else if let defaults = action.defaultBinding {
                bindings[action] = defaults
            }
        }
    }

    func binding(for action: AshShortcutAction) -> ShortcutBinding? { bindings[action] }

    func record(_ event: NSEvent, for action: AshShortcutAction) {
        guard let newBinding = ShortcutBinding(event: event) else {
            message = "请按下至少包含一个修饰键的组合键。"
            return
        }
        if let conflict = bindings.first(where: { $0.key != action && $0.value == newBinding })?.key {
            message = "\(newBinding.display) 已分配给“\(conflict.title)”。"
            return
        }
        bindings[action] = newBinding
        message = "已设置：\(newBinding.display)"
        persist()
        recordingAction = nil
    }

    func reset() {
        bindings = Dictionary(uniqueKeysWithValues: AshShortcutAction.allCases.compactMap { action in
            action.defaultBinding.map { (action, $0) }
        })
        message = "已恢复默认快捷键。"
        persist()
    }

    func install(perform: @escaping (AshShortcutAction) -> Void) {
        self.perform = perform
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if let action = self.recordingAction {
                Task { @MainActor in self.record(event, for: action) }
                return nil
            }
            if NSApp.modalWindow != nil || NSApp.keyWindow?.isSheet == true || NSApp.keyWindow?.attachedSheet != nil {
                return event
            }
            if let action = self.bindings.first(where: { $0.value.matches(event) })?.key {
                Task { @MainActor in self.perform?(action) }
                return nil
            }
            return event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func persist() {
        var saved: [String: [String: Any]] = [:]
        for (action, binding) in bindings {
            saved[action.rawValue] = ["keyCode": Int(binding.keyCode), "modifiers": binding.modifiers.rawValue, "keyName": binding.keyName]
        }
        UserDefaults.standard.set(saved, forKey: "ash.shortcutBindings")
    }
}

struct FocusShortcutSettings: View {
    @ObservedObject var shortcuts: FocusShortcutController
    @Environment(\.dismiss) private var dismiss
    private let accent = Color(red: 0.48, green: 0.35, blue: 0.83)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("快捷键", systemImage: "keyboard").font(.system(size: 18, weight: .semibold))
            Text("点击右侧按钮后，直接按下想设置的组合键。快捷键保存在本机。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AshShortcutAction.allCases) { action in
                        HStack {
                            Text(action.title).font(.system(size: 12))
                            Spacer(minLength: 8)
                            Button {
                                shortcuts.message = nil
                                shortcuts.recordingAction = action
                            } label: {
                                Text(shortcuts.recordingAction == action ? "请按快捷键…" : (shortcuts.binding(for: action)?.display ?? "未设置"))
                                    .font(.system(size: 11, weight: .medium, design: .rounded))
                                    .frame(minWidth: 128, alignment: .center)
                            }
                            .buttonStyle(.bordered).tint(shortcuts.recordingAction == action ? accent : .secondary)
                        }
                    }
                }
            }.frame(maxHeight: 390)
            if let message = shortcuts.message {
                Text(message).font(.system(size: 11)).foregroundStyle(shortcuts.recordingAction == nil ? accent : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("恢复默认") { shortcuts.reset() }
                Spacer()
                Button("完成") { shortcuts.recordingAction = nil; dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440, height: 590)
        .background(.background)
        .onDisappear { shortcuts.recordingAction = nil }
    }
}
