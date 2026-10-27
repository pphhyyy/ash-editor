import SwiftUI
import Combine

struct WorkspaceFileNode: Identifiable, Equatable {
    let url: URL
    let isDirectory: Bool
    var children: [WorkspaceFileNode] = []
    var id: String { url.path }
}

/// Keep the folder grant alive while browsing its children, and restore it on
/// the next launch. A file grant alone does not authorize listing its parent.
@MainActor
final class FolderWorkspace: ObservableObject {
    @Published private(set) var rootURL: URL?
    @Published private(set) var nodes: [WorkspaceFileNode] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var expandedPaths: Set<String> = []

    private let defaults: UserDefaults
    private var accessingRoot = false
    private var grantedURL: URL?
    private let bookmarkKey = "ash.workspace.folderBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            try open(url)
        } catch {
            errorMessage = "文件夹授权已失效，请重新选择文件夹。"
        }
    }

    deinit {
        if accessingRoot { grantedURL?.stopAccessingSecurityScopedResource() }
    }

    func open(_ url: URL) throws {
        let started = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            // Validate the new folder before releasing the previous grant.
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                            options: .skipsHiddenFiles)
            if accessingRoot { rootURL?.stopAccessingSecurityScopedResource() }
            rootURL = url
            grantedURL = url
            accessingRoot = started
            expandedPaths = []
            defaults.set(bookmark, forKey: bookmarkKey)
            refresh()
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func toggle(_ url: URL) {
        if expandedPaths.contains(url.path) { expandedPaths.remove(url.path) }
        else { expandedPaths.insert(url.path) }
        refresh()
    }

    func refresh() {
        guard let rootURL else { return }
        do {
            let updated = try children(of: rootURL)
            if nodes != updated { nodes = updated }
            errorMessage = nil
        } catch {
            nodes = []
            errorMessage = "无法读取文件夹：\(error.localizedDescription)"
        }
    }

    private func children(of directory: URL) throws -> [WorkspaceFileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles)
        return urls.compactMap { url -> WorkspaceFileNode? in
            guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return nil }
            if values.isDirectory == true {
                let childNodes = expandedPaths.contains(url.path) ? ((try? children(of: url)) ?? []) : []
                return WorkspaceFileNode(url: url, isDirectory: true, children: childNodes)
            }
            guard values.isRegularFile == true,
                  ["ash", "md", "markdown"].contains(url.pathExtension.lowercased()) else { return nil }
            return WorkspaceFileNode(url: url, isDirectory: false)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }
}

struct WorkspaceFileTreeRow: View {
    let node: WorkspaceFileNode
    @ObservedObject var folder: FolderWorkspace
    let selectedURL: URL?
    let accent: Color
    let ink: Color
    let onOpen: (URL) -> Void
    let onReveal: (URL) -> Void
    let onTrash: (URL) -> Void
    var depth = 0

    private var expanded: Bool { folder.expandedPaths.contains(node.url.path) }
    private var selected: Bool { selectedURL?.standardizedFileURL == node.url.standardizedFileURL }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                if node.isDirectory { folder.toggle(node.url) } else { onOpen(node.url) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: node.isDirectory ? (expanded ? "chevron.down" : "chevron.right") : "circle.fill")
                        .font(.system(size: node.isDirectory ? 8 : 3, weight: .semibold))
                        .frame(width: 8).foregroundStyle(ink.opacity(0.45))
                    Image(systemName: node.isDirectory ? (expanded ? "folder.fill" : "folder") :
                            (node.url.pathExtension.lowercased() == "ash" ? "lock.doc" : "doc.text"))
                        .foregroundStyle(accent).frame(width: 15)
                    Text(node.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(ink)
                .padding(.vertical, 7).padding(.trailing, 6)
                .padding(.leading, CGFloat(depth) * 12 + 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(node.url.path)
            .contextMenu {
                Button("在访达中显示") { onReveal(node.url) }
                if !node.isDirectory {
                    Divider()
                    Button("删除文件…", role: .destructive) { onTrash(node.url) }
                }
            }
            if node.isDirectory && expanded {
                if node.children.isEmpty {
                    Text("没有 ASH / Markdown 文件")
                        .font(.system(size: 9)).foregroundStyle(ink.opacity(0.45))
                        .padding(.leading, CGFloat(depth + 1) * 12 + 18).padding(.vertical, 4)
                } else {
                    ForEach(node.children) { child in
                        WorkspaceFileTreeRow(node: child, folder: folder, selectedURL: selectedURL,
                            accent: accent, ink: ink, onOpen: onOpen, onReveal: onReveal,
                            onTrash: onTrash, depth: depth + 1)
                    }
                }
            }
        }
    }
}
