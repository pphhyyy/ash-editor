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

    func encode(_ document: AshDocument) throws -> Data {
        switch self {
        case .markdown: return Data(document.markdown.utf8)
        case .defaultEncrypted: return try AshFile.sealDefault(document)
        case .personalEncrypted(let password): return try AshFile.seal(document, password: password)
        case .legacyLocal: return try AshFile.sealLocal(document)
        }
    }

    static func suggestedName(title: String, source: URL?, markdown: Bool) -> String {
        var name = source?.deletingPathExtension().lastPathComponent ?? title.trimmingCharacters(in: .whitespacesAndNewlines)
        while ["ash", "md", "markdown"].contains((name as NSString).pathExtension.lowercased()) {
            name = (name as NSString).deletingPathExtension
        }
        if name.isEmpty { name = "未命名" }
        return name + (markdown ? ".md" : ".ash")
    }
}
