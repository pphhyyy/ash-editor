import AppKit
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

enum ASHImageAssets {
    private static let legacyLibraryName = "ASH资源库"
    private static let imageLibraryFolderName = "ASH-editor"
    private static let imageFolderName = "img"
    private static let documentsBookmarkKey = "ash.imageLibrary.documentsBookmark"
    private static let draftDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ASH/UnsavedImageAssets", isDirectory: true)
    }()
    private static let derivedKeys = NSCache<NSString, NSData>()
    private static let maximumImageBytes = 64 * 1024 * 1024

    private enum Format: Equatable {
        case jpeg, png
        var plainExtension: String { self == .jpeg ? "jpg" : "png" }
        var encryptedExtension: String { self == .jpeg ? "ashj" : "ashp" }
        var mimeType: String { self == .jpeg ? "image/jpeg" : "image/png" }
        var magic: Data { Data((self == .jpeg ? "ASHJ" : "ASHP").utf8) }

        static func detect(_ data: Data) -> Self? {
            if data.starts(with: Data([0xFF, 0xD8, 0xFF])) { return .jpeg }
            if data.starts(with: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) { return .png }
            return nil
        }

        static func fromEncrypted(_ data: Data) -> Self? {
            if data.starts(with: Data("ASHJ".utf8)) { return .jpeg }
            if data.starts(with: Data("ASHP".utf8)) { return .png }
            return nil
        }

        static func fromPlainFilename(_ name: String) -> Self? {
            switch URL(fileURLWithPath: name).pathExtension.lowercased() {
            case "jpg", "jpeg": .jpeg
            case "png": .png
            default: nil
            }
        }

        static func fromEncryptedFilename(_ name: String) -> Self? {
            switch URL(fileURLWithPath: name).pathExtension.lowercased() {
            case "ashj": .jpeg
            case "ashp": .png
            default: nil
            }
        }
    }

    struct PreparedSave {
        let markdown: String
        let plaintextFilesToRemove: [URL]

        @MainActor func finishAfterDocumentSave() {
            removePlaintextFiles(plaintextFilesToRemove)
        }
    }

    private struct ImageLibraryAuthorizationRequired: Error {}

    private static var systemDocumentsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true)
    }

    @MainActor
    private static func withImageLibrary<T>(_ operation: (URL) throws -> T) throws -> T {
        guard let bookmark = UserDefaults.standard.data(forKey: documentsBookmarkKey) else {
            throw ImageLibraryAuthorizationRequired()
        }
        var stale = false
        let documents: URL
        do {
            documents = try URL(resolvingBookmarkData: bookmark,
                                options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                                bookmarkDataIsStale: &stale)
        } catch {
            throw ImageLibraryAuthorizationRequired()
        }
        let started = documents.startAccessingSecurityScopedResource()
        guard started else { throw ImageLibraryAuthorizationRequired() }
        defer { documents.stopAccessingSecurityScopedResource() }

        if stale, let refreshed = try? documents.bookmarkData(options: .withSecurityScope,
                                                               includingResourceValuesForKeys: nil,
                                                               relativeTo: nil) {
            UserDefaults.standard.set(refreshed, forKey: documentsBookmarkKey)
        }
        let library = documents.appendingPathComponent(imageLibraryFolderName, isDirectory: true)
            .appendingPathComponent(imageFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        return try operation(library)
    }

    @MainActor
    private static func withAuthorizedImageLibrary<T>(_ operation: (URL) throws -> T) throws -> T {
        do { return try withImageLibrary(operation) }
        catch is ImageLibraryAuthorizationRequired {
            try requestDocumentsAuthorization()
            return try withImageLibrary(operation)
        }
    }

    @MainActor
    private static func requestDocumentsAuthorization() throws {
        let panel = NSOpenPanel()
        panel.title = "设置 ASH 图片资源位置"
        panel.message = "请选择系统“文稿”文件夹。ASH 会在其中创建 ASH-editor/img，用来统一保存粘贴的图片。"
        panel.prompt = "选择文稿文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = systemDocumentsURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let selected = panel.url else {
            throw imageError("没有授权图片资源文件夹，图片未粘贴。")
        }
        let selectedPath = selected.standardizedFileURL.resolvingSymlinksInPath().path
        let documentsPath = systemDocumentsURL.standardizedFileURL.resolvingSymlinksInPath().path
        guard selectedPath == documentsPath else {
            throw imageError("请选择系统“文稿”文件夹，ASH 图片资源库固定保存在其中。")
        }

        let started = selected.startAccessingSecurityScopedResource()
        defer { if started { selected.stopAccessingSecurityScopedResource() } }
        let library = selected.appendingPathComponent(imageLibraryFolderName, isDirectory: true)
            .appendingPathComponent(imageFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let bookmark = try selected.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: documentsBookmarkKey)
    }

    @MainActor
    private static func removePlaintextFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let imageRoot = systemDocumentsURL.appendingPathComponent(imageLibraryFolderName, isDirectory: true)
            .appendingPathComponent(imageFolderName, isDirectory: true).standardizedFileURL.path + "/"
        let globalFiles = urls.filter { $0.standardizedFileURL.path.hasPrefix(imageRoot) }
        if !globalFiles.isEmpty {
            try? withImageLibrary { _ in
                for url in globalFiles { try? FileManager.default.removeItem(at: url) }
            }
        }
        for url in urls where !globalFiles.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Reads an image from the native clipboard, avoiding a base64 copy through WebKit.
    static func imageFromPasteboard() -> (data: Data, mimeType: String)? {
        let pasteboard = NSPasteboard.general
        let candidates: [(String, String)] = [
            ("public.png", "image/png"), ("public.jpeg", "image/jpeg"), ("public.jpg", "image/jpeg")
        ]
        for (typeName, mime) in candidates {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(typeName)),
               data.count <= maximumImageBytes, Format.detect(data) != nil {
                return (data, mime)
            }
        }

        // Clipboard providers use more image UTIs than the common PNG/JPEG
        // pair (for example TIFF, HEIC, and browser-specific image formats).
        for type in pasteboard.types ?? [] {
            guard UTType(type.rawValue)?.conforms(to: .image) == true,
                  let data = pasteboard.data(forType: type), data.count <= maximumImageBytes else { continue }
            if let format = Format.detect(data) { return (data, format.mimeType) }
            if let image = NSImage(data: data), let png = pngData(from: image) { return (png, "image/png") }
        }

        // WebKit and some clipboard providers expose images as NSImage objects
        // without a public.png/public.jpeg data representation.
        let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) ?? []
        for case let image as NSImage in images {
            if let png = pngData(from: image) { return (png, "image/png") }
        }

        var fileURLs: [URL] = []
        if let path = pasteboard.string(forType: .fileURL), let url = URL(string: path), url.isFileURL {
            fileURLs.append(url)
        }
        let urlObjects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        fileURLs.append(contentsOf: urlObjects.compactMap { ($0 as? NSURL).map { $0 as URL } })
        for url in fileURLs {
            guard let data = try? Data(contentsOf: url), data.count <= maximumImageBytes else { continue }
            if let format = Format.detect(data) { return (data, format.mimeType) }
            if let image = NSImage(data: data), let png = pngData(from: image) { return (png, "image/png") }
        }
        return nil
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, tiff.count <= maximumImageBytes,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= maximumImageBytes else { return nil }
        return png
    }

    /// New clipboard images stay ordinary JPEG/PNG files until the note is saved.
    @MainActor
    static func storeDraft(_ data: Data, mimeType: String, in _: URL?) throws -> String {
        guard data.count <= maximumImageBytes, let format = Format.detect(data) else {
            throw imageError("只支持 PNG 和 JPEG 图片，且图片不能超过 64 MB。")
        }
        if mimeType != format.mimeType && mimeType != "application/octet-stream" {
            throw imageError("剪贴板图片格式和图片内容不一致，无法导入。")
        }
        let id = UUID().uuidString.lowercased()
        let filename = "\(id).\(format.plainExtension)"
        try withAuthorizedImageLibrary { library in
            try data.write(to: library.appendingPathComponent(filename), options: .atomic)
        }
        return "ash-draft://\(filename)"
    }

    /// Move local images into the stable Documents library, encrypt them, and
    /// write portable ASH asset references into the note.
    @MainActor
    static func prepareForSave(markdown: String, destination: URL, workspaceRoot: URL?, storage: DocumentStorage,
                               sourceURL: URL?, sourceStorage: DocumentStorage,
                               readData: ((URL) throws -> Data)? = nil) throws -> PreparedSave {
        let read = readData ?? { try Data(contentsOf: $0) }
        let pattern = #"!\[[^\]]*\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let matches = regex.matches(in: markdown, range: NSRange(markdown.startIndex..<markdown.endIndex, in: markdown))
        guard !matches.isEmpty else { return PreparedSave(markdown: markdown, plaintextFilesToRemove: []) }

        let root = workspaceRoot?.standardizedFileURL
        let sameCredential = sourceStorage.imageCredentialIdentifier == storage.imageCredentialIdentifier
        return try withAuthorizedImageLibrary { library in
            var updated = markdown
            var plaintextSources = Set<URL>()

            for match in matches.reversed() {
                let destinationGroup = match.range(at: 1).location != NSNotFound ? 1 : 2
                guard let referenceRange = Range(match.range(at: destinationGroup), in: updated) else { continue }
                let reference = String(updated[referenceRange])
                if reference.hasPrefix("http://") || reference.hasPrefix("https://") || reference.hasPrefix("data:") {
                    continue
                }

                let isDraft = reference.hasPrefix("ash-draft://")
                let managedFilename = assetFilename(in: reference)
                let path = reference.removingPercentEncoding ?? reference
                let pathExtension = managedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
                    ?? URL(fileURLWithPath: path).pathExtension.lowercased()
                guard ["jpg", "jpeg", "png", "ashj", "ashp"].contains(pathExtension) else { continue }

                let sourceAsset: URL?
                if isDraft {
                    let filename = String(reference.dropFirst("ash-draft://".count))
                    sourceAsset = draftURL(filename: filename, library: library, workspaceRoot: root,
                                           targetDirectory: sourceURL?.deletingLastPathComponent())
                } else if let managedFilename {
                    sourceAsset = library.appendingPathComponent(managedFilename)
                } else if let sourceURL {
                    sourceAsset = imageURL(reference, documentURL: sourceURL, workspaceRoot: root)
                } else {
                    sourceAsset = nil
                }
                guard let sourceAsset else {
                    if isDraft || pathExtension == "ashp" || pathExtension == "ashj" {
                        throw imageError("图片资源“\(reference)”找不到；请确认原图片文件仍可访问后再保存。")
                    }
                    continue
                }

                let sourceData: Data
                do { sourceData = try read(sourceAsset) }
                catch {
                    if isDraft || pathExtension == "ashp" || pathExtension == "ashj" {
                        throw imageError("图片资源“\(reference)”无法读取：\(error.localizedDescription)")
                    }
                    continue
                }

                guard let format = Format.fromEncrypted(sourceData) ?? Format.detect(sourceData) else {
                    if isDraft || pathExtension == "ashp" || pathExtension == "ashj" {
                        throw imageError("图片“\(reference)”的内容与格式不匹配，无法迁移。")
                    }
                    continue
                }
                let extensionFormat: Format? = pathExtension == "ashj" ? .jpeg : (pathExtension == "ashp" ? .png : nil)
                if let extensionFormat, Format.fromEncrypted(sourceData) != extensionFormat {
                    throw imageError("加密图片“\(reference)”的扩展名与内容不匹配。")
                }

                let isAlreadyCentral = !isDraft && managedFilename != nil
                    && sourceAsset.deletingLastPathComponent().standardizedFileURL == library.standardizedFileURL
                let targetAsset: URL
                if isAlreadyCentral, Format.fromEncrypted(sourceData) == format, sameCredential {
                    targetAsset = sourceAsset
                } else {
                    let desiredName: String
                    if isDraft {
                        desiredName = URL(fileURLWithPath: sourceAsset.lastPathComponent)
                            .deletingPathExtension().lastPathComponent + "." + format.encryptedExtension
                    } else {
                        desiredName = UUID().uuidString.lowercased() + "." + format.encryptedExtension
                    }
                    targetAsset = unusedAssetURL(in: library, desiredName: desiredName)

                    let encryptedData: Data
                    if let encryptedFormat = Format.fromEncrypted(sourceData), sameCredential {
                        // The authenticated header carries its salt, so a same-key
                        // migration can copy bytes without decrypting/resealing.
                        encryptedData = sourceData
                        guard encryptedFormat == format else { throw imageError("加密图片格式无效。") }
                    } else {
                        let clearData: Data
                        if let encryptedFormat = Format.fromEncrypted(sourceData) {
                            clearData = try open(sourceData, format: encryptedFormat, storage: sourceStorage)
                        } else {
                            clearData = sourceData
                        }
                        encryptedData = try seal(clearData, format: format, storage: storage, library: library)
                    }
                    try encryptedData.write(to: targetAsset, options: .atomic)
                }

                if isDraft { plaintextSources.insert(sourceAsset) }
                updated.replaceSubrange(referenceRange, with: assetReference(for: targetAsset.lastPathComponent))
            }
            return PreparedSave(markdown: updated, plaintextFilesToRemove: Array(plaintextSources))
        }
    }

    /// Decrypts an image only into the WebKit request buffer; the stored asset stays encrypted.
    @MainActor
    static func load(_ reference: String, documentURL: URL?, workspaceRoot: URL?, storage: DocumentStorage,
                     readData: ((URL) throws -> Data)? = nil) throws -> (Data, String) {
        let read = readData ?? { try Data(contentsOf: $0) }
        if reference.hasPrefix("ash-draft://") {
            let filename = String(reference.dropFirst("ash-draft://".count))
            return try withAuthorizedImageLibrary { library in
                guard let source = draftURL(filename: filename, library: library, workspaceRoot: workspaceRoot,
                                            targetDirectory: documentURL?.deletingLastPathComponent()) else {
                    throw imageError("待保存图片不存在。")
                }
                let data = try read(source)
                guard let format = Format.detect(data) else { throw imageError("图片格式无法识别。") }
                return (data, format.mimeType)
            }
        }
        if let filename = assetFilename(in: reference) {
            return try withAuthorizedImageLibrary { library in
                let assetURL = library.appendingPathComponent(filename)
                let data = try read(assetURL)
                guard let format = Format.fromEncrypted(data),
                      Format.fromEncryptedFilename(filename) == format else {
                    throw imageError("加密图片“\(filename)”损坏或格式不匹配。")
                }
                return (try open(data, format: format, storage: storage), format.mimeType)
            }
        }

        guard let url = imageURL(reference, documentURL: documentURL, workspaceRoot: workspaceRoot) else {
            throw imageError("图片路径无效。")
        }
        let data = try read(url)
        if let format = Format.fromEncrypted(data) {
            return (try open(data, format: format, storage: storage), format.mimeType)
        }
        guard let format = Format.detect(data) else { throw imageError("ASH 只能预览 PNG 和 JPEG 图片。") }
        return (data, format.mimeType)
    }

    private static func seal(_ data: Data, format: Format, storage: DocumentStorage, library: URL) throws -> Data {
        let salt = try librarySalt(in: library)
        let nonce = AES.GCM.Nonce()
        let local = storage.imagePassword == nil
        let key = try encryptionKey(storage: storage, salt: salt)
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
        return format.magic + Data([1, local ? 1 : 0]) + salt + Data(nonce) + sealed.ciphertext + sealed.tag
    }

    private static func open(_ data: Data, format: Format, storage: DocumentStorage) throws -> Data {
        guard data.count >= 50, data.prefix(4) == format.magic, data[4] == 1 else {
            throw imageError("加密图片格式无效。")
        }
        let local = data[5] == 1
        let salt = data.subdata(in: 6..<22)
        let nonce = try AES.GCM.Nonce(data: data.subdata(in: 22..<34))
        let box = try AES.GCM.SealedBox(nonce: nonce,
            ciphertext: data.subdata(in: 34..<(data.count - 16)), tag: data.suffix(16))
        do {
            let key = try encryptionKey(storage: storage, salt: salt)
            guard local == (storage.imagePassword == nil) else { throw imageError("这张加密图片需要使用保存它的 ASH 密码打开。") }
            return try AES.GCM.open(box, using: key)
        } catch let failure as NSError where failure.domain == "ASH.Image" { throw failure }
        catch { throw imageError("图片解密失败；请确认打开的是原 ASH 文档，并使用保存时的密码。") }
    }

    private static func encryptionKey(storage: DocumentStorage, salt: Data) throws -> SymmetricKey {
        guard let password = storage.imagePassword else { return try AshFile.localKey() }
        let cacheMaterial = Data(password.utf8) + salt
        let cacheName = SHA256.hash(data: cacheMaterial).map { String(format: "%02x", $0) }.joined() as NSString
        if let cached = derivedKeys.object(forKey: cacheName) { return SymmetricKey(data: cached as Data) }
        let key = try AshFile.deriveKey(password, salt: salt)
        derivedKeys.setObject(key.withUnsafeBytes { Data($0) } as NSData, forKey: cacheName)
        return key
    }

    private static func librarySalt(in library: URL) throws -> Data {
        let saltURL = library.appendingPathComponent(".ash-image-salt")
        if let existing = try? Data(contentsOf: saltURL), existing.count == 16 { return existing }
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw imageError("无法生成图片加密随机数。") }
        try salt.write(to: saltURL, options: .atomic)
        return salt
    }

    private static func draftURL(filename: String, library: URL, workspaceRoot: URL?, targetDirectory: URL?) -> URL? {
        guard filename.range(of: #"^[0-9a-fA-F-]{36}\.(?:jpg|jpeg|png)$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        let candidates = [
            library.appendingPathComponent(filename),
            workspaceRoot?.appendingPathComponent(legacyLibraryName, isDirectory: true).appendingPathComponent(filename),
            targetDirectory?.appendingPathComponent(legacyLibraryName, isDirectory: true).appendingPathComponent(filename),
            draftDirectory.appendingPathComponent(filename),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func assetFilename(in reference: String) -> String? {
        let prefix = "ash-asset://"
        guard reference.hasPrefix(prefix) else { return nil }
        let filename = String(reference.dropFirst(prefix.count))
        guard filename.range(of: #"^[0-9a-fA-F-]{36}\.(?:ashj|ashp)$"#,
                             options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        return filename
    }

    private static func assetReference(for filename: String) -> String {
        "ash-asset://\(filename)"
    }

    private static func imageURL(_ reference: String, documentURL: URL?, workspaceRoot: URL?) -> URL? {
        guard !reference.isEmpty, !reference.hasPrefix("http://"), !reference.hasPrefix("https://") else { return nil }
        let decoded = reference.removingPercentEncoding ?? reference
        if let url = URL(string: decoded), url.isFileURL { return url.standardizedFileURL }
        guard URL(string: decoded)?.scheme == nil else { return nil }
        let base = documentURL?.deletingLastPathComponent() ?? workspaceRoot
        guard let base else { return nil }
        let resolved = base.appendingPathComponent(decoded).standardizedFileURL
        let root = workspaceRoot?.standardizedFileURL
        let insideWorkspace = root.map { resolved.path == $0.path || resolved.path.hasPrefix($0.path + "/") } ?? false
        let insideDocumentFolder = resolved.path == base.standardizedFileURL.path || resolved.path.hasPrefix(base.standardizedFileURL.path + "/")
        // Legacy image libraries may sit above the currently selected folder.
        // Resolve them from the document URL so changing workspaces cannot
        // silently redirect an old relative image path.
        let isLegacyLibraryAsset = resolved.pathComponents.contains(legacyLibraryName)
            && Format.fromEncryptedFilename(resolved.lastPathComponent) != nil
        return insideWorkspace || insideDocumentFolder || isLegacyLibraryAsset ? resolved : nil
    }

    private static func unusedAssetURL(in library: URL, desiredName: String) -> URL {
        let desired = library.appendingPathComponent(desiredName)
        guard FileManager.default.fileExists(atPath: desired.path) else { return desired }
        let ext = URL(fileURLWithPath: desiredName).pathExtension
        return library.appendingPathComponent(UUID().uuidString.lowercased() + (ext.isEmpty ? "" : "." + ext))
    }

    private static func imageError(_ message: String) -> NSError {
        NSError(domain: "ASH.Image", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
