import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DocumentTabItem: Identifiable {
    let id: UUID
    let title: String
    let dirty: Bool
    let path: String?
}

// Private formats keep tab/file transfers out of the Markdown editor's text
// drop handling. Both the native tab strip and SwiftUI pane use these formats.
enum ASHEditorDragType {
    static let tab = UTType(exportedAs: "app.ash.editor.document-tab", conformingTo: .data)
    static let file = UTType(exportedAs: "app.ash.editor.workspace-file", conformingTo: .data)
    static let tabPasteboard = NSPasteboard.PasteboardType(tab.identifier)
    static let filePasteboard = NSPasteboard.PasteboardType(file.identifier)
}

enum ASHEditorDragPayload: Equatable {
    case tab(UUID)
    case file(URL)

    var encoded: String {
        switch self {
        case .tab(let id): return "ash-tab:\(id.uuidString)"
        case .file(let url): return "ash-file:\(url.standardizedFileURL.path)"
        }
    }
    var type: UTType {
        switch self {
        case .tab: return ASHEditorDragType.tab
        case .file: return ASHEditorDragType.file
        }
    }
    static func decode(_ value: String) -> Self? {
        if value.hasPrefix("ash-tab:"), let id = UUID(uuidString: String(value.dropFirst(8))) { return .tab(id) }
        if value.hasPrefix("ash-file:") { return .file(URL(fileURLWithPath: String(value.dropFirst(9)))) }
        return nil
    }
    static func read(from pasteboard: NSPasteboard) -> Self? {
        for type in [ASHEditorDragType.tabPasteboard, ASHEditorDragType.filePasteboard] {
            if let value = pasteboard.string(forType: type), let payload = decode(value) { return payload }
        }
        return nil
    }
}

func makeASHEditorDragProvider(_ payload: ASHEditorDragPayload) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = Data(payload.encoded.utf8)
    provider.registerDataRepresentation(forTypeIdentifier: payload.type.identifier, visibility: .ownProcess) { complete in
        complete(data, nil)
        return nil
    }
    return provider
}

@discardableResult
func loadASHEditorDragPayload(from info: DropInfo, completion: @escaping (ASHEditorDragPayload) -> Void) -> Bool {
    for type in [ASHEditorDragType.tab, ASHEditorDragType.file] {
        guard let provider = info.itemProviders(for: [type]).first else { continue }
        // Load only on the actual drop; hovering does not need asynchronous data.
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let value = String(data: data, encoding: .utf8),
                  let payload = ASHEditorDragPayload.decode(value) else { return }
            DispatchQueue.main.async { completion(payload) }
        }
        return true
    }
    return false
}

struct DocumentPaneDropDelegate: DropDelegate {
    let moveTab: (UUID) -> Bool
    let openFile: (URL) -> Void
    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [ASHEditorDragType.tab, ASHEditorDragType.file])
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [ASHEditorDragType.tab]) ? .move : .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        loadASHEditorDragPayload(from: info) { payload in
            switch payload {
            case .tab(let id): _ = moveTab(id)
            case .file(let url): openFile(url)
            }
        }
    }
}

struct DocumentTabBar: NSViewRepresentable {
    let items: [DocumentTabItem]
    let selected: UUID
    let accent: Color
    let ink: Color
    let select: (UUID) -> Void
    let close: (UUID) -> Void
    let new: () -> Void
    let allowsWindowDrag: Bool
    let leadingInset: CGFloat
    let windowControlExclusion: CGFloat
    let moveRight: (UUID) -> Void
    let moveBelow: (UUID) -> Void
    let moveDroppedTab: (UUID, UUID?) -> Bool
    let openDroppedFile: (URL) -> Void

    func makeNSView(context: Context) -> NativeDocumentTabBar { NativeDocumentTabBar(frame: .zero) }
    func updateNSView(_ view: NativeDocumentTabBar, context: Context) {
        view.configure(items: items, selected: selected, accent: NSColor(accent), ink: NSColor(ink),
                       allowsWindowDrag: allowsWindowDrag, leadingInset: leadingInset,
                       windowControlExclusion: windowControlExclusion, select: select, close: close,
                       new: new, moveRight: moveRight, moveBelow: moveBelow,
                       moveTab: moveDroppedTab, openFile: openDroppedFile)
    }
}

// One NSControl owns mouse routing and native drag source/destination handling.
// There is no titlebar gesture or hit-test overlay on top of the tabs.
// NSControl is deliberate: unlike a plain NSView, AppKit excludes its bounds
// from the WindowServer titlebar drag region. mouseDownCanMoveWindow alone
// does not provide that exclusion for a full-size content view on macOS 26.
// This lets tab events reach us; only .windowBackground explicitly starts a move.
final class NativeDocumentTabBar: NSControl, NSDraggingSource {
    enum Hit: Equatable {
        case tab(UUID), close(UUID), new, windowBackground, none
    }
    private(set) var items: [DocumentTabItem] = []
    private var selected: UUID?
    private var accent = NSColor.systemPurple
    private var ink = NSColor.labelColor
    private var allowsWindowDrag = false
    private var leadingInset: CGFloat = 0
    private var windowControlExclusion: CGFloat = 0
    private var scrollOffset: CGFloat = 0
    private var frames: [UUID: CGRect] = [:]
    private var pressed: Hit = .none
    private var downEvent: NSEvent?
    private var sourceID: UUID?
    private var markerX: CGFloat?
    private var selectTab: (UUID) -> Void = { _ in }
    private var closeTab: (UUID) -> Void = { _ in }
    private var newTab: () -> Void = {}
    private var moveRight: (UUID) -> Void = { _ in }
    private var moveBelow: (UUID) -> Void = { _ in }
    private var moveTab: (UUID, UUID?) -> Bool = { _, _ in false }
    private var openFile: (URL) -> Void = { _ in }
    private let tabFont = NSFont.systemFont(ofSize: 11)

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: allowsWindowDrag ? 43 : 34) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([ASHEditorDragType.tabPasteboard, ASHEditorDragType.filePasteboard])
        setAccessibilityElement(false)
        setAccessibilityRole(.tabGroup)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(items: [DocumentTabItem], selected: UUID, accent: NSColor, ink: NSColor,
                   allowsWindowDrag: Bool, leadingInset: CGFloat, windowControlExclusion: CGFloat,
                   select: @escaping (UUID) -> Void, close: @escaping (UUID) -> Void,
                   new: @escaping () -> Void, moveRight: @escaping (UUID) -> Void,
                   moveBelow: @escaping (UUID) -> Void, moveTab: @escaping (UUID, UUID?) -> Bool,
                   openFile: @escaping (URL) -> Void) {
        let selectionChanged = self.selected != selected
        let dragModeChanged = self.allowsWindowDrag != allowsWindowDrag
        self.items = items; self.selected = selected; self.accent = accent; self.ink = ink
        self.allowsWindowDrag = allowsWindowDrag; self.leadingInset = leadingInset
        self.windowControlExclusion = windowControlExclusion
        selectTab = select; closeTab = close; newTab = new
        self.moveRight = moveRight; self.moveBelow = moveBelow; self.moveTab = moveTab; self.openFile = openFile
        rebuildFrames()
        if dragModeChanged { invalidateIntrinsicContentSize() }
        if selectionChanged { revealSelected() }
        rebuildAccessibility()
        needsDisplay = true
    }

    // Keep a narrow strip above the tabs available for an explicit window drag.
    // It is outside both the tab and new-button hit regions.
    private var topInset: CGFloat { allowsWindowDrag ? 10 : 1 }
    private var tabHeight: CGFloat { max(0, bounds.height - topInset - 1) }
    private var viewport: CGRect {
        CGRect(x: leadingInset, y: topInset, width: max(0, bounds.width - leadingInset - 30), height: tabHeight)
    }
    private var plusFrame: CGRect { CGRect(x: max(0, bounds.width - 30), y: topInset, width: 30, height: tabHeight) }
    private func width(of item: DocumentTabItem) -> CGFloat {
        let textWidth = (item.title as NSString).size(withAttributes: [.font: tabFont]).width
        return min(201, max(118, ceil(textWidth) + (item.dirty ? 62 : 52)))
    }
    private func rebuildFrames() {
        let total = items.reduce(CGFloat(10)) { $0 + width(of: $1) + 2 }
        scrollOffset = min(max(0, scrollOffset), max(0, total - viewport.width))
        var x = leadingInset + 5 - scrollOffset
        frames = [:]
        for item in items {
            let width = width(of: item)
            frames[item.id] = CGRect(x: x, y: topInset, width: width, height: tabHeight)
            x += width + 2
        }
    }
    private func revealSelected() {
        guard let selected, let frame = frames[selected] else { return }
        if frame.minX < viewport.minX { scrollOffset -= viewport.minX - frame.minX }
        if frame.maxX > viewport.maxX { scrollOffset += frame.maxX - viewport.maxX }
        rebuildFrames()
    }
    override func layout() {
        super.layout()
        rebuildFrames()
        rebuildAccessibility()
        needsDisplay = true
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); rebuildAccessibility() }

    func hit(at point: CGPoint) -> Hit {
        guard bounds.contains(point) else { return .none }
        if plusFrame.contains(point) { return .new }
        if viewport.contains(point) {
            for item in items {
                guard let frame = frames[item.id], frame.contains(point) else { continue }
                return closeFrame(frame).contains(point) ? .close(item.id) : .tab(item.id)
            }
        }
        return allowsWindowDrag && point.x >= windowControlExclusion ? .windowBackground : .none
    }
    private func closeFrame(_ frame: CGRect) -> CGRect {
        CGRect(x: frame.maxX - 25, y: frame.minY + 3, width: 22, height: 26)
    }
    override func mouseDown(with event: NSEvent) {
        pressed = hit(at: convert(event.locationInWindow, from: nil))
        downEvent = event
        if pressed == .windowBackground {
            downEvent = nil
            window?.performDrag(with: event)
        }
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = .none; downEvent = nil }
        guard hit(at: convert(event.locationInWindow, from: nil)) == pressed else { return }
        switch pressed {
        case .tab(let id): selectTab(id)
        case .close(let id): closeTab(id)
        case .new: newTab()
        default: break
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard case .tab(let id) = pressed, let downEvent,
              let item = items.first(where: { $0.id == id }), let frame = frames[id] else { return }
        let origin = convert(downEvent.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - origin.x, current.y - origin.y) >= 4 else { return }
        let payload = ASHEditorDragPayload.tab(id)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload.encoded, forType: ASHEditorDragType.tabPasteboard)
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(frame, contents: dragImage(item: item, size: frame.size))
        sourceID = id
        pressed = .none; self.downEvent = nil
        let session = beginDraggingSession(with: [draggingItem], event: downEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        sourceID = nil; pressed = .none; downEvent = nil; markerX = nil; needsDisplay = true
    }
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        scrollOffset -= delta
        rebuildFrames(); rebuildAccessibility(); needsDisplay = true
    }

    // The same insertion calculation supplies both the marker and the drop.
    func insertionTarget(at point: CGPoint, moving id: UUID) -> UUID? {
        items.first { item in item.id != id && point.x < (frames[item.id]?.midX ?? -.infinity) }?.id
    }
    private func updateDrop(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = ASHEditorDragPayload.read(from: sender.draggingPasteboard) else { return [] }
        let point = convert(sender.draggingLocation, from: nil)
        switch payload {
        case .tab(let id):
            if let target = insertionTarget(at: point, moving: id) {
                markerX = frames[target]?.minX
            } else {
                markerX = items.last(where: { $0.id != id }).flatMap { frames[$0.id]?.maxX } ?? viewport.minX + 5
            }
            markerX = markerX.map { min(viewport.maxX - 2, max(viewport.minX + 1, $0)) }
            needsDisplay = true
            return .move
        case .file:
            markerX = nil; needsDisplay = true
            return .copy
        }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { updateDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { markerX = nil; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        ASHEditorDragPayload.read(from: sender.draggingPasteboard) != nil
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { markerX = nil; needsDisplay = true }
        guard let payload = ASHEditorDragPayload.read(from: sender.draggingPasteboard) else { return false }
        switch payload {
        case .tab(let id): return moveTab(id, insertionTarget(at: convert(sender.draggingLocation, from: nil), moving: id))
        case .file(let url): openFile(url); return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ink.withAlphaComponent(0.035).setFill(); NSBezierPath(rect: bounds).fill()
        ink.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: max(0, bounds.height - 1), width: bounds.width, height: 1)).fill()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()
        for item in items {
            if let frame = frames[item.id], frame.intersects(viewport) {
                drawTab(item, frame: frame, selected: item.id == selected)
            }
        }
        if let markerX {
            accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: markerX - 1.5, y: topInset + 5, width: 3, height: max(0, tabHeight - 10)), xRadius: 1, yRadius: 1).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        drawCross(center: CGPoint(x: plusFrame.midX, y: plusFrame.midY), plus: true, color: ink.withAlphaComponent(0.65))
    }
    private func drawTab(_ item: DocumentTabItem, frame: CGRect, selected: Bool) {
        if selected {
            accent.withAlphaComponent(0.12).setFill(); NSBezierPath(rect: frame).fill()
            accent.setFill(); NSBezierPath(rect: CGRect(x: frame.minX, y: frame.maxY - 2, width: frame.width, height: 2)).fill()
        }
        if let symbol = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) {
            let image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [accent])) ?? symbol
            image.draw(in: CGRect(x: frame.minX + 10, y: frame.midY - 6, width: 11, height: 12),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let rightSpace: CGFloat = item.dirty ? 36 : 26
        let textRect = CGRect(x: frame.minX + 27, y: frame.midY - 7,
                              width: max(0, frame.width - 27 - rightSpace), height: 15)
        (item.title as NSString).draw(in: textRect, withAttributes: [.font: tabFont, .foregroundColor: ink, .paragraphStyle: paragraph])
        if item.dirty {
            accent.setFill()
            NSBezierPath(ovalIn: CGRect(x: frame.maxX - 34, y: frame.midY - 2.5, width: 5, height: 5)).fill()
        }
        drawCross(center: CGPoint(x: closeFrame(frame).midX, y: frame.midY), plus: false, color: ink.withAlphaComponent(0.55))
    }
    private func drawCross(center: CGPoint, plus: Bool, color: NSColor) {
        let path = NSBezierPath(); path.lineWidth = plus ? 1.2 : 1
        let radius: CGFloat = plus ? 5 : 3.2
        if plus {
            path.move(to: CGPoint(x: center.x - radius, y: center.y)); path.line(to: CGPoint(x: center.x + radius, y: center.y))
            path.move(to: CGPoint(x: center.x, y: center.y - radius)); path.line(to: CGPoint(x: center.x, y: center.y + radius))
        } else {
            path.move(to: CGPoint(x: center.x - radius, y: center.y - radius)); path.line(to: CGPoint(x: center.x + radius, y: center.y + radius))
            path.move(to: CGPoint(x: center.x + radius, y: center.y - radius)); path.line(to: CGPoint(x: center.x - radius, y: center.y + radius))
        }
        color.setStroke(); path.stroke()
    }
    private func dragImage(item: DocumentTabItem, size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 6, yRadius: 6).fill()
        drawTab(item, frame: CGRect(origin: .zero, size: size), selected: true)
        image.unlockFocus()
        return image
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let hit = hit(at: convert(event.locationInWindow, from: nil))
        let id: UUID
        switch hit { case .tab(let value), .close(let value): id = value; default: return nil }
        let menu = NSMenu()
        for (title, action) in [("移到另一栏并左右显示", #selector(moveRightFromMenu(_:))),
                                ("移到另一栏并上下显示", #selector(moveBelowFromMenu(_:))),
                                ("关闭标签页", #selector(closeFromMenu(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.representedObject = id; menu.addItem(item)
        }
        return menu
    }
    @objc private func moveRightFromMenu(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { moveRight(id) } }
    @objc private func moveBelowFromMenu(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { moveBelow(id) } }
    @objc private func closeFromMenu(_ item: NSMenuItem) { if let id = item.representedObject as? UUID { closeTab(id) } }

    private func rebuildAccessibility() {
        guard let window else { return }
        func element(_ label: String, frame: CGRect, role: NSAccessibility.Role = .button,
                     action: @escaping () -> Void) -> TabAccessibilityElement {
            let child = TabAccessibilityElement()
            child.setAccessibilityParent(self)
            child.setAccessibilityRole(role); child.setAccessibilityLabel(label)
            child.setAccessibilityFrame(window.convertToScreen(convert(frame, to: nil)))
            child.press = action
            return child
        }
        var children: [NSAccessibilityElement] = []
        for item in items {
            guard let frame = frames[item.id] else { continue }
            let visible = frame.intersection(viewport)
            guard !visible.isNull, visible.width > 0 else { continue }
            let tab = element(item.title, frame: visible, role: .radioButton) { [weak self] in self?.selectTab(item.id) }
            tab.setAccessibilityValue(item.id == selected ? 1 : 0)
            children.append(tab)
            let close = closeFrame(frame).intersection(viewport)
            if !close.isNull, close.width > 0 {
                children.append(element("关闭标签：\(item.title)", frame: close) { [weak self] in self?.closeTab(item.id) })
            }
        }
        children.append(element("新建标签页", frame: plusFrame) { [weak self] in self?.newTab() })
        setAccessibilityChildren(children)
    }
}

private final class TabAccessibilityElement: NSAccessibilityElement {
    var press: () -> Void = {}
    override func accessibilityPerformPress() -> Bool { press(); return true }
}
