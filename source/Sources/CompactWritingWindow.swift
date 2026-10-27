import AppKit
import SwiftUI

/// An independent, resizable view of the active document, with no submission buffer.
@MainActor
final class CompactWritingWindow: NSObject, ObservableObject, NSWindowDelegate {
    @Published var text = "" {
        didSet { if text != oldValue { onEdit?(text) } }
    }
    @Published var concealed = false
    @Published var fading = false
    @Published var fadeInitialOpacity = 0.35
    @Published var fadeDuration = 4.0
    @Published var fontSize = 18.0
    @Published var ink = Color.primary
    @Published var canvas = Color.white
    @Published var alignment = "left"
    @Published private(set) var isPinned = UserDefaults.standard.bool(forKey: "ash.compactWindowPinned")
    private var onEdit: ((String) -> Void)?
    private var onExit: (() -> Void)?
    private var window: NSWindow?
    private var previousActivationPolicy: NSApplication.ActivationPolicy?
    private var spaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?

    func present(text: String, concealed: Bool, size: Double, ink: Color, canvas: Color,
                 alignment: String, edit: @escaping (String) -> Void, exit: @escaping () -> Void) {
        onEdit = nil
        self.text = text; self.concealed = concealed; self.fontSize = size
        self.ink = ink; self.canvas = canvas; self.alignment = alignment
        onEdit = edit; onExit = exit
        if window == nil {
            let window = CompactWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 120),
                                       styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            window.contentMinSize = NSSize(width: 160, height: 60)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = false
            window.hasShadow = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isMovableByWindowBackground = true
            window.delegate = self
            self.window = window
            window.center()
            let saved = UserDefaults.standard.string(forKey: "ash.compactWindowFrame") ?? ""
            let frame = NSRectFromString(saved)
            if frame.width >= 160, frame.height >= 60,
               NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: false)
            }
        }
        // A regular foreground app is tied to its main window's Space. During the
        // compact session, act as an accessory so activating the IME does not
        // take the user away from another app's full-screen Space.
        if previousActivationPolicy == nil {
            previousActivationPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.accessory)
        }
        observeInputFocus()
        applyPinning()
        // Recreate only when opening: each session starts with the caret at the document end.
        window?.contentView = NSHostingView(rootView: CompactWritingView(model: self))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        focusEditor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.focusEditor() }
    }

    func dismiss() {
        if let window { UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: "ash.compactWindowFrame") }
        onEdit = nil; onExit = nil
        window?.orderOut(nil)
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        spaceObserver = nil; activationObserver = nil
        if let previousActivationPolicy {
            NSApp.setActivationPolicy(previousActivationPolicy)
            self.previousActivationPolicy = nil
        }
    }

    func requestExit() { onExit?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestExit(); return false }
    func windowDidBecomeKey(_ notification: Notification) {
        // IME candidates must belong to the active app in the current Space.
        NSApp.activate(ignoringOtherApps: true)
        focusEditor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusEditor() }
    }

    /// Activate the accessory app in the panel's current Space, without raising
    /// a document window or making the auxiliary panel a main window.
    func activateForTyping() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        focusEditor()
    }

    private func observeInputFocus() {
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                // Switching Spaces is not permission to steal keyboard focus.
                // Reorder the pinned panel in the new Space without activation.
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isVisible else { return }
                    if self.isPinned { window.orderFrontRegardless() }
                    guard NSApp.isActive, window.isKeyWindow else { return }
                    self.focusEditor()
                }
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window?.isKeyWindow == true else { return }
                    self.focusEditor()
                }
            }
        }
    }

    private func focusEditor() {
        guard let window, window.isVisible, window.isKeyWindow,
              let editor = Self.findTextView(in: window.contentView) else { return }
        if window.firstResponder !== editor { window.makeFirstResponder(editor) }
        if let input = editor.inputContext {
            // Do not restart a composition session each time the window refreshes.
            if NSTextInputContext.current !== input { input.activate() }
            input.invalidateCharacterCoordinates()
        }
    }

    func windowDidMove(_ notification: Notification) { refreshCandidatePosition() }
    func windowDidResize(_ notification: Notification) { refreshCandidatePosition() }

    private func refreshCandidatePosition() {
        guard let window, window.isKeyWindow,
              let editor = Self.findTextView(in: window.contentView) else { return }
        editor.inputContext?.invalidateCharacterCoordinates()
    }

    private static func findTextView(in view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let editor = view as? NSTextView { return editor }
        for subview in view.subviews {
            if let editor = findTextView(in: subview) { return editor }
        }
        return nil
    }

    func togglePinned() {
        isPinned.toggle()
        UserDefaults.standard.set(isPinned, forKey: "ash.compactWindowPinned")
        applyPinning()
        // Updating the window level must not activate ASH or leave the current full-screen app.
        if window?.isVisible == true { window?.orderFrontRegardless() }
    }

    private func applyPinning() {
        guard let panel = window as? NSPanel else { return }
        panel.isFloatingPanel = isPinned
        panel.level = isPinned ? .floating : .normal
        // canJoinAllSpaces and moveToActiveSpace are mutually exclusive.
        // canJoinAllApplications permits joining other apps' full-screen / Stage Manager spaces.
        panel.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }
}

private final class CompactWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { (delegate as? CompactWritingWindow)?.requestExit() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            (delegate as? CompactWritingWindow)?.activateForTyping()
        }
        super.sendEvent(event)
    }
}

private struct CompactWritingView: View {
    @ObservedObject var model: CompactWritingWindow
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CompactDragArea().frame(maxWidth: .infinity)
                Button { model.togglePinned() } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(model.ink.opacity(model.isPinned ? 0.9 : 0.62))
                        .frame(width: 24, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusable(false)
                .accessibilityLabel(model.isPinned ? "取消置顶聊天框" : "置顶聊天框")
                .help(model.isPinned ? "取消跨桌面置顶" : "固定在所有桌面及全屏应用上方")
            }.frame(height: 16).padding(.trailing, 3)
                .background(model.ink.opacity(0.045))
            AshTextEditor(text: $model.text, size: model.fontSize, color: model.ink,
                          concealed: model.concealed, focusMode: true, alignment: model.alignment,
                          fading: model.fading, fadeInitialOpacity: model.fadeInitialOpacity, fadeDuration: model.fadeDuration,
                          focusToken: 1, showsScrollIndicators: false, startAtEnd: true,
                          onCancel: { model.requestExit() })
                .padding(.horizontal, 5).padding(.bottom, 5)
        }
        .frame(minWidth: 160, minHeight: 60)
        .background(model.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}

private struct CompactDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
