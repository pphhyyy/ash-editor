import SwiftUI

struct DocumentTabItem: Identifiable {
    let id: UUID
    let title: String
    let dirty: Bool
    let path: String?
}

struct DocumentTabBar: View {
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var draggingTabID: UUID?
    @State private var dropSlot: TabDropSlot?
    @State private var dropMarkerX: CGFloat?
    @State private var dragTranslation: CGSize = .zero

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
                    }
                    .padding(.horizontal, 5)
                    .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
                }
                .onChange(of: selected) { _, id in reader.scrollTo(id, anchor: .center) }
            }
            Button(action: new) { Image(systemName: "plus").frame(width: 30, height: 32) }
                .buttonStyle(.plain).foregroundStyle(ink.opacity(0.65))
                .help("新建标签页").accessibilityLabel("新建标签页")
        }
        .frame(height: 34)
        .background(ink.opacity(0.035))
        .overlay(alignment: .bottom) {
            Rectangle().fill(ink.opacity(0.08)).frame(height: 1).allowsHitTesting(false)
        }
        .coordinateSpace(name: "document-tab-strip")
        .overlay(alignment: .topLeading) {
            if let dropMarkerX {
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 3, height: 22)
                    .offset(x: dropMarkerX, y: 6)
                    .allowsHitTesting(false)
            }
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
        .contentShape(Rectangle())
        .onTapGesture { select(item.id) }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TabFramePreferenceKey.self,
                                       value: [item.id: proxy.frame(in: .named("document-tab-strip"))])
            }
        }
        .highPriorityGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("document-tab-strip"))
            .onChanged { value in
                if draggingTabID == nil { draggingTabID = item.id }
                guard draggingTabID == item.id else { return }
                dragTranslation = value.translation
                dropSlot = insertionSlot(at: value.location, moving: item.id)
                dropMarkerX = markerX(for: dropSlot)
            }
            .onEnded { value in
                guard draggingTabID == item.id else { return }
                let slot = insertionSlot(at: value.location, moving: item.id)
                dropSlot = slot
                dropMarkerX = markerX(for: slot)
                withAnimation(.easeOut(duration: 0.14)) {
                    if value.translation.width.magnitude >= 4 || value.translation.height.magnitude >= 4 {
                        switch slot {
                        case .before(let target): _ = reorder(item.id, target)
                        case .end: _ = reorder(item.id, nil)
                        case nil: break
                        }
                    }
                    draggingTabID = nil
                    dropSlot = nil
                    dropMarkerX = nil
                    dragTranslation = .zero
                }
            }
        )
        .offset(draggingTabID == item.id ? dragTranslation : .zero)
        .scaleEffect(draggingTabID == item.id ? 1.025 : 1)
        .shadow(color: .black.opacity(draggingTabID == item.id ? 0.14 : 0), radius: 5, y: 2)
        .zIndex(draggingTabID == item.id ? 10 : 0)
        .contextMenu {
            Button("移到另一栏并左右显示", systemImage: "rectangle.split.2x1") { moveRight(item.id) }
            Button("移到另一栏并上下显示", systemImage: "rectangle.split.1x2") { moveBelow(item.id) }
            Divider()
            Button("关闭标签页", systemImage: "xmark") { close(item.id) }
        }
        .help(item.path ?? item.title)
    }

    private func insertionSlot(at point: CGPoint, moving id: UUID) -> TabDropSlot? {
        let otherItems = items.filter { $0.id != id }
        guard !otherItems.isEmpty else { return .end }

        if let item = otherItems.first(where: { tabFrames[$0.id]?.contains(point) == true }),
           let frame = tabFrames[item.id], let index = otherItems.firstIndex(where: { $0.id == item.id }) {
            if point.x < frame.midX { return .before(item.id) }
            if index + 1 < otherItems.count { return .before(otherItems[index + 1].id) }
            return .end
        }

        if let last = otherItems.last, let frame = tabFrames[last.id], point.x >= frame.maxX {
            return .end
        }
        return nil
    }

    private func markerX(for slot: TabDropSlot?) -> CGFloat? {
        switch slot {
        case .before(let id): return tabFrames[id]?.minX
        case .end:
            guard let lastID = items.last(where: { $0.id != draggingTabID })?.id else { return nil }
            return tabFrames[lastID]?.maxX
        case nil: return nil
        }
    }

}

private enum TabDropSlot: Equatable {
    case before(UUID)
    case end
}

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}
