import Foundation

/// Kept in memory for each open document. Personal passwords are never written to preferences.
enum DocumentStorage {
    case markdown
    case defaultEncrypted
    case personalEncrypted(String)
    case legacyLocal

    var isMarkdown: Bool {
        if case .markdown = self { return true }
        return false
    }

    /// Image assets use the same credential as the document container. Plain
    /// Markdown has no password, so its resource library uses ASH's default key.
    var imagePassword: String? {
        switch self {
        case .markdown, .defaultEncrypted: AshFile.defaultPassword
        case .personalEncrypted(let password): password
        case .legacyLocal: nil
        }
    }

    var imageCredentialIdentifier: String {
        imagePassword.map { "password:\($0)" } ?? "local-keychain"
    }

    func encode(_ document: AshDocument) throws -> Data {
        switch self {
        case .markdown: return Data(document.markdown.utf8)
        case .defaultEncrypted: return try AshFile.sealDefault(document)
        case .personalEncrypted(let password): return try AshFile.seal(document, password: password)
        case .legacyLocal: return try AshFile.sealLocal(document)
        }
    }

    static func synchronizedURL(title: String, source: URL) throws -> URL {
        var name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = source.pathExtension.isEmpty ? "" : "." + source.pathExtension
        if !suffix.isEmpty && name.lowercased().hasSuffix(suffix.lowercased()) {
            name = String(name.dropLast(suffix.count))
        }
        if name.isEmpty { name = source.deletingPathExtension().lastPathComponent }
        guard name != ".", name != "..", name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:\0").union(.newlines)) == nil else {
            throw NSError(domain: "ASH.Save", code: 2, userInfo: [NSLocalizedDescriptionKey: "标题不能包含斜杠、冒号或换行，请修改标题后保存。"])
        }
        return source.deletingLastPathComponent().appendingPathComponent(name + suffix)
    }

    /// Coordinate renaming with macOS so file-scoped sandbox access follows the
    /// new name. Save atomically before moving; a failed move leaves the saved
    /// contents at the original path. Never replace a different existing file.
    static func save(_ data: Data, to source: URL, renamingTo destination: URL) throws -> URL {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            try data.write(to: source, options: .atomic)
            return source
        }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var outcome: Result<URL, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: [], error: &coordinationError) { oldURL, newURL in
            outcome = Result {
                if FileManager.default.fileExists(atPath: newURL.path) {
                    let oldID = try oldURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
                    let newID = try newURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject
                    let caseOnly = oldURL.lastPathComponent.caseInsensitiveCompare(newURL.lastPathComponent) == .orderedSame
                    guard caseOnly, let oldID, let newID, oldID == newID else {
                        throw NSError(domain: "ASH.Save", code: 3, userInfo: [NSLocalizedDescriptionKey: "同一文件夹已存在“\(newURL.lastPathComponent)”，请更换标题或使用另存为。"])
                    }
                }
                coordinator.item(at: oldURL, willMoveTo: newURL)
                try data.write(to: oldURL, options: .atomic)
                do { try FileManager.default.moveItem(at: oldURL, to: newURL) }
                catch {
                    throw NSError(domain: "ASH.Save", code: 4, userInfo: [NSLocalizedDescriptionKey: "内容已保存到“\(oldURL.lastPathComponent)”，但重命名失败：\(error.localizedDescription)"])
                }
                coordinator.item(at: oldURL, didMoveTo: newURL)
                return newURL
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        return try outcome.get()
    }

    static func suggestedName(title: String, source: URL?, markdown: Bool) -> String {
        let editedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = editedTitle.isEmpty ? (source?.deletingPathExtension().lastPathComponent ?? "未命名") : editedTitle
        while ["ash", "md", "markdown"].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
        }
        if name.isEmpty { name = "未命名" }
        return name + (markdown ? ".md" : ".ash")
    }
}
