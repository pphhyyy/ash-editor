import Foundation
import Combine

struct RecentDocumentEntry: Codable, Identifiable, Equatable {
    var path: String
    var lastOpenedAt: Date
    var id: String { path }
}

private struct RecentIndexFile: Codable {
    var version = 1
    var documents: [RecentDocumentEntry]
}

private struct RecentAccessBookmark: Codable {
    var path: String
    var bookmark: Data
}

@MainActor
final class RecentDocumentIndex: ObservableObject {
    @Published private(set) var documents: [RecentDocumentEntry] = []
    @Published private(set) var errorMessage: String?
    let indexURL: URL

    private let defaults: UserDefaults
    private var bookmarks: [RecentAccessBookmark] = []
    private var resolvedURLs: [String: URL] = [:]
    private var lastData: Data?
    private var loaded = false
    private let bookmarksKey = "ash.recentDocumentBookmarks"

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory,
                                                         in: .userDomainMask).first!.appendingPathComponent("ASH", isDirectory: true)
        indexURL = base.appendingPathComponent("recent-documents.json")
        if let text = defaults.string(forKey: bookmarksKey) {
            bookmarks = (try? JSONDecoder().decode([RecentAccessBookmark].self, from: Data(text.utf8))) ?? []
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                try load()
            } else {
                let legacy = defaults.bool(forKey: "ash.recentIndexMigrated") ? "[]" :
                    (defaults.string(forKey: "ash.recentDocuments") ?? "[]")
                let paths = (try? JSONDecoder().decode([String].self, from: Data(legacy.utf8))) ?? []
                var seen = Set<String>()
                let entries = paths.enumerated().compactMap { offset, path -> RecentDocumentEntry? in
                    guard seen.insert(path).inserted else { return nil }
                    return RecentDocumentEntry(path: path, lastOpenedAt: Date().addingTimeInterval(-Double(offset)))
                }
                try persist(entries)
            }
        } catch { errorMessage = "无法读取最近文档索引：\(error.localizedDescription)" }
    }

    func resolvedURL(for entry: RecentDocumentEntry) -> URL {
        if let cached = resolvedURLs[entry.path] { return cached }
        guard let stored = bookmarks.first(where: { $0.path == entry.path }),
              let url = resolve(stored) else { return URL(fileURLWithPath: entry.path) }
        resolvedURLs[entry.path] = url
        return url
    }

    func hasBookmark(for url: URL) -> Bool {
        guard let stored = bookmarks.first(where: { $0.path == url.path || resolvedURLs[$0.path] == url }) else { return false }
        return resolve(stored)?.standardizedFileURL == url.standardizedFileURL
    }

    func remember(_ url: URL) throws {
        try load()
        let removed = matchingPaths(url)
        var updated = documents.filter { !removed.contains($0.path) }
        updated.insert(RecentDocumentEntry(path: url.path, lastOpenedAt: Date()), at: 0)
        // No entry-count limit: the JSON is a long-lived navigation index.
        try persist(updated)
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                          includingResourceValuesForKeys: nil, relativeTo: nil) {
            bookmarks.removeAll { removed.contains($0.path) }
            bookmarks.append(RecentAccessBookmark(path: url.path, bookmark: data))
            for path in removed { resolvedURLs.removeValue(forKey: path) }
            resolvedURLs[url.path] = url
            saveBookmarks()
        }
    }

    func remove(_ url: URL) throws {
        try load()
        let removed = matchingPaths(url)
        try persist(documents.filter { !removed.contains($0.path) })
        bookmarks.removeAll { removed.contains($0.path) }
        for path in removed { resolvedURLs.removeValue(forKey: path) }
        saveBookmarks()
    }

    func reload() {
        do { try load() }
        catch { errorMessage = "最近文档索引无法读取，请检查 JSON：\(error.localizedDescription)" }
    }

    private func matchingPaths(_ url: URL) -> Set<String> {
        Set(bookmarks.filter { $0.path == url.path || resolvedURLs[$0.path]?.standardizedFileURL == url.standardizedFileURL }
            .map(\.path)).union([url.path])
    }

    private func resolve(_ stored: RecentAccessBookmark) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: stored.bookmark, options: [.withSecurityScope, .withoutUI],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func load() throws {
        if !FileManager.default.fileExists(atPath: indexURL.path) { try persist([]); return }
        let data = try Data(contentsOf: indexURL)
        if loaded && data == lastData { errorMessage = nil; return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(RecentIndexFile.self, from: data)
        guard file.version == 1 else {
            throw NSError(domain: "ASH.RecentIndex", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "不支持此索引版本"])
        }
        var seen = Set<String>()
        documents = file.documents.filter { !$0.path.isEmpty && seen.insert($0.path).inserted }
        lastData = data
        loaded = true
        errorMessage = nil
        defaults.set(true, forKey: "ash.recentIndexMigrated")
    }

    private func persist(_ entries: [RecentDocumentEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(RecentIndexFile(documents: entries))
        try data.write(to: indexURL, options: .atomic)
        documents = entries
        lastData = data
        loaded = true
        errorMessage = nil
        defaults.set(true, forKey: "ash.recentIndexMigrated")
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: bookmarksKey)
        }
    }
}
