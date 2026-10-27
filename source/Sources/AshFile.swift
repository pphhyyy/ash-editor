import Foundation
import CryptoKit
import CommonCrypto
import Security

struct AshDocument: Codable {
    var version = 1
    var title: String
    var markdown: String
    var fontSize: Int
    var alignment: String
    var theme: String
    var backgroundHex: String? = nil
    var fontHex: String? = nil
}

enum AshFileError: LocalizedError {
    case unsupported, invalidPassword, invalidPayload, keyUnavailable
    var errorDescription: String? {
        switch self {
        case .unsupported: "这不是受支持的 ASH 文件。"
        case .invalidPassword: "密码错误，或文件内容已损坏。"
        case .invalidPayload: "ASH 文档内容无法读取。"
        case .keyUnavailable: "无法从 macOS 钥匙串读取或创建本机加密密钥。"
        }
    }
}

/// Version-1 container shared byte-for-byte with Android's AshFile.kt.
enum AshFile {
    static let iterations: UInt32 = 600_000
    static let magic = Data([0x41, 0x53, 0x48, 0x31])
    static let defaultMagic = Data([0x41, 0x53, 0x48, 0x44])
    static let defaultPassword = "Asahi0423"

    /// Per-installation key stored in Keychain; explicit-password files remain interoperable.
    static func localKey() throws -> SymmetricKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.ash.editor",
            kSecAttrAccount as String: "local-encryption-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }

        var keyBytes = Data(count: 32)
        let randomStatus = keyBytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw AshFileError.keyUnavailable }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.ash.editor",
            kSecAttrAccount as String: "local-encryption-key",
            kSecValueData as String: keyBytes,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return SymmetricKey(data: keyBytes) }
        if status == errSecDuplicateItem,
           SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data { return SymmetricKey(data: data) }
        throw AshFileError.keyUnavailable
    }

    static func sealLocal(_ document: AshDocument) throws -> Data {
        let nonce = AES.GCM.Nonce()
        let json = try JSONEncoder().encode(document)
        let sealed = try AES.GCM.seal(json, using: localKey(), nonce: nonce)
        return Data([0x41, 0x53, 0x48, 0x4c, 0x01]) + Data(nonce) + sealed.ciphertext + sealed.tag
    }

    static func openLocal(_ data: Data) throws -> AshDocument {
        guard data.count >= 33, data.prefix(5) == Data([0x41, 0x53, 0x48, 0x4c, 0x01]) else { throw AshFileError.unsupported }
        do {
            let nonce = try AES.GCM.Nonce(data: data.subdata(in: 5..<17))
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: data.subdata(in: 17..<(data.count - 16)), tag: data.suffix(16))
            let document = try JSONDecoder().decode(AshDocument.self, from: AES.GCM.open(box, using: localKey()))
            guard document.version == 1 else { throw AshFileError.unsupported }
            return document
        } catch let error as AshFileError { throw error }
        catch { throw AshFileError.invalidPassword }
    }

    static func isLocal(_ data: Data) -> Bool { data.prefix(5) == Data([0x41, 0x53, 0x48, 0x4c, 0x01]) }

    static func seal(_ document: AshDocument, password: String) throws -> Data {
        try seal(document, password: password, magic: magic)
    }

    static func sealDefault(_ document: AshDocument) throws -> Data {
        try seal(document, password: defaultPassword, magic: defaultMagic)
    }

    private static func seal(_ document: AshDocument, password: String, magic: Data) throws -> Data {
        let salt = random(count: 16)
        let nonceBytes = random(count: 12)
        let key = try deriveKey(password, salt: salt)
        let json = try JSONEncoder().encode(document)
        let nonce = try AES.GCM.Nonce(data: nonceBytes)
        let sealed = try AES.GCM.seal(json, using: key, nonce: nonce)
        return magic + salt + nonceBytes + sealed.ciphertext + sealed.tag
    }

    static func open(_ data: Data, password: String) throws -> AshDocument {
        try open(data, password: password, magic: magic)
    }

    static func openDefault(_ data: Data) throws -> AshDocument {
        try open(data, password: defaultPassword, magic: defaultMagic)
    }

    private static func open(_ data: Data, password: String, magic: Data) throws -> AshDocument {
        guard data.count >= 48, data.prefix(4) == magic else { throw AshFileError.unsupported }
        let salt = data.subdata(in: 4..<20)
        let nonceData = data.subdata(in: 20..<32)
        let ciphertext = data.subdata(in: 32..<(data.count - 16))
        let tag = data.suffix(16)
        do {
            let key = try deriveKey(password, salt: salt)
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            let clear = try AES.GCM.open(box, using: key)
            let document = try JSONDecoder().decode(AshDocument.self, from: clear)
            guard document.version == 1 else { throw AshFileError.unsupported }
            return document
        } catch let error as AshFileError { throw error }
        catch { throw AshFileError.invalidPassword }
    }

    static func isDefault(_ data: Data) -> Bool { data.prefix(4) == defaultMagic }

    static func deriveKey(_ password: String, salt: Data) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = password.utf8CString.withUnsafeBufferPointer { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pass.baseAddress!, pass.count - 1,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &bytes, bytes.count)
            }
        }
        guard result == kCCSuccess else { throw AshFileError.invalidPayload }
        return SymmetricKey(data: bytes)
    }

    private static func random(count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
}
