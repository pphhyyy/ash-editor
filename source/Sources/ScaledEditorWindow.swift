import SwiftUI

/// One continuous layout in logical points. UI zoom never changes the document's font-size setting.
struct ScaledEditorWindow: View {
    @AppStorage("ash.uiScale") private var uiScale = 1.0
    private var scale: Double { min(1.5, max(0.75, uiScale)) }
    var body: some View {
        GeometryReader { bounds in
            EditorView()
                .frame(width: bounds.size.width / scale, height: bounds.size.height / scale)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: bounds.size.width, height: bounds.size.height, alignment: .topLeading)
        }
        // The hidden title bar still reserves a top safe-area inset. Let the
        // editor use that space so its toolbar sits closer to the window edge.
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 760 * scale, minHeight: 600 * scale)
    }
}
