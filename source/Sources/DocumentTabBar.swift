import AppKit
import SwiftUI

struct DocumentTabItem: Identifiable {
    let id: UUID
    let title: String
    let dirty: Bool
    let path: String?
}

struct DocumentTabBar: View {
    let items: [DocumentTabItem]
    let selected: UUID
    let accent: Color
    let ink: Color
    let select: (UUID) -> Void
    let close: (UUID) -> Void
    let new: () -> Void
    let moveRight: (UUID) -> Void
    let moveBelow: (UUID) -> Void
    let reorder: (UUID, UUID?) -> Bool

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(items) { item in tab(item).id(item.id) }
                        Color.clear.frame(width: 36, height: 32)
                    }.padding(.horizontal, 5)
                }
                .onChange(of: selected) { _, id in reader.scrollTo(id, anchor: .center) }
            }
            Button(action: new) { Image(systemName: "plus").frame(width: 30, height: 32) }
                .buttonStyle(.plain).foregroundStyle(ink.opacity(0.65))
                .help("新建标签页").accessibilityLabel("新建标签页")
        }
        .frame(height: 34)
        .background(ink.opacity(0.035))
        .overlay { NativeTabDropArea(isTab: false, receive: { reorder($0, nil) }) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ink.opacity(0.08)).frame(height: 1).allowsHitTesting(false)
        }
        .zIndex(2)
    }

    private func tab(_ item: DocumentTabItem) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").foregroundStyle(accent)
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if item.dirty { Circle().fill(accent).frame(width: 5, height: 5) }
            }
            .font(.system(size: 11)).foregroundStyle(ink)
            .frame(minWidth: 65, maxWidth: 165, alignment: .leading)
            .frame(height: 32)
            .overlay {
                NativeTabDragHandle(id: item.id, title: item.title,
                                    select: { select(item.id) },
                                    moveRight: { moveRight(item.id) }, moveBelow: { moveBelow(item.id) },
                                    close: { close(item.id) })
            }
            Button { close(item.id) } label: {
                Image(systemName: "xmark").font(.system(size: 9)).frame(width: 19, height: 26)
            }
            .buttonStyle(.plain).foregroundStyle(ink.opacity(0.55))
            .accessibilityLabel("关闭标签：\(item.title)")
        }
        .padding(.leading, 10).padding(.trailing, 3).frame(height: 32)
        .background(selected == item.id ? accent.opacity(0.12) : Color.clear)
        .overlay(alignment: .bottom) {
            if selected == item.id { Rectangle().fill(accent).frame(height: 2).allowsHitTesting(false) }
        }
        .overlay { NativeTabDropArea(isTab: true, receive: { reorder($0, item.id) }) }
        .help(item.path ?? item.title)
    }
}

/// Native view conversion includes window, scrolling, backing scale and UI zoom.
/// No SwiftUI global gesture coordinates or delayed pasteboard hand-off are needed.
@MainActor private final class TabDropRegistry {
    static let shared = TabDropRegistry()
    private final class WeakRegion {
        weak var view: NativeTabDropArea.Region?
        init(_ view: NativeTabDropArea.Region) { self.view = view }
    }
    private var regions: [WeakRegion] = []
    private weak var highlighted: NativeTabDropArea.Region?
    func add(_ view: NativeTabDropArea.Region) { regions.append(WeakRegion(view)) }
    func target(at screenPoint: NSPoint, in window: NSWindow?) -> NativeTabDropArea.Region? {
        regions.removeAll { $0.view == nil }
        guard let window else { return nil }
        let point = window.convertPoint(fromScreen: screenPoint)
        return regions.compactMap(\.view).filter { view in
            guard view.window === window, !view.isHidden else { return false }
            let local = view.convert(point, from: nil)
            return view.bounds.contains(local) && view.visibleRect.contains(local)
        }.sorted { $0.isTab && !$1.isTab }.first
    }
    func highlight(_ view: NativeTabDropArea.Region?) {
        guard highlighted !== view else { return }
        highlighted?.highlighted = false
        highlighted = view
        highlighted?.highlighted = true
    }
}

private struct NativeTabDropArea: NSViewRepresentable {
    let isTab: Bool
    let receive: (UUID) -> Bool
    func makeNSView(context: Context) -> Region {
        let view = Region()
        TabDropRegistry.shared.add(view)
        return view
    }
    func updateNSView(_ view: Region, context: Context) { view.isTab = isTab; view.receive = receive }
    final class Region: NSView {
        var isTab = false
        var receive: (UUID) -> Bool = { _ in false }
        var highlighted = false { didSet { needsDisplay = true } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            guard highlighted else { return }
            NSColor.controlAccentColor.withAlphaComponent(isTab ? 0.9 : 0.2).setFill()
            NSBezierPath(rect: isTab ? NSRect(x: 0, y: 0, width: 3, height: bounds.height) : bounds).fill()
        }
    }
}

private struct NativeTabDragHandle: NSViewRepresentable {
    let id: UUID
    let title: String
    let select: () -> Void
    let moveRight: () -> Void
    let moveBelow: () -> Void
    let close: () -> Void

    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) {
        view.tabID = id; view.title = title; view.select = select
        view.moveRight = moveRight; view.moveBelow = moveBelow; view.close = close
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.button)
        view.setAccessibilityLabel("切换标签：\(title)")
    }

    final class Handle: NSView {
        var tabID = UUID()
        var title = ""
        var select: () -> Void = {}
        var moveRight: () -> Void = {}
        var moveBelow: () -> Void = {}
        var close: () -> Void = {}
        private var downEvent: NSEvent?
        private var dragging = false
        private var preview: NSPanel?
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func accessibilityPerformPress() -> Bool { select(); return true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) { downEvent = event; dragging = false }
        override func mouseUp(with event: NSEvent) {
            let target = window.flatMap { TabDropRegistry.shared.target(at: $0.convertPoint(toScreen: event.locationInWindow), in: $0) }
            let wasDragging = dragging
            finishDrag()
            if wasDragging { _ = target?.receive(tabID) } else { select() }
        }
        override func mouseDragged(with event: NSEvent) {
            guard let downEvent, let window,
                  hypot(event.locationInWindow.x-downEvent.locationInWindow.x,
                        event.locationInWindow.y-downEvent.locationInWindow.y) >= 4 else { return }
            if !dragging {
                dragging = true
                let size = NSSize(width: max(90,bounds.width), height: 32)
                let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                panel.isOpaque = false; panel.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9)
                panel.isReleasedWhenClosed = false
                panel.hasShadow = true; panel.ignoresMouseEvents = true; panel.level = .floating
                let label = NSTextField(labelWithString: title)
                label.frame = NSRect(x: 7, y: 8, width: size.width-14, height: 18)
                label.font = .systemFont(ofSize: 11, weight: .medium)
                panel.contentView?.addSubview(label)
                preview = panel
            }
            let point = window.convertPoint(toScreen: event.locationInWindow)
            preview?.setFrameOrigin(NSPoint(x: point.x+8, y: point.y-40))
            preview?.orderFront(nil)
            NSCursor.closedHand.set()
            TabDropRegistry.shared.highlight(TabDropRegistry.shared.target(at: point, in: window))
        }
        private func finishDrag() {
            preview?.close(); preview = nil
            TabDropRegistry.shared.highlight(nil)
            dragging = false; downEvent = nil
            NSCursor.arrow.set()
        }
        override func cancelOperation(_ sender: Any?) { finishDrag() }
        override func rightMouseDown(with event: NSEvent) {
            let menu = NSMenu()
            for (title, selector) in [("移到另一栏并左右显示", #selector(moveRightAction)),
                                      ("移到另一栏并上下显示", #selector(moveBelowAction)),
                                      ("关闭标签页", #selector(closeAction))] {
                let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
                item.target = self; menu.addItem(item)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        @objc private func moveRightAction() { moveRight() }
        @objc private func moveBelowAction() { moveBelow() }
        @objc private func closeAction() { close() }
    }
}
