import CryptoKit
import Foundation

/// Native resume data can contain archived authenticated requests. Only an
/// encrypted opaque blob reaches disk; its key never leaves this device's
/// Keychain. Associated data binds every blob to its account and resource.
actor DownloadResumeVault {
    private let directory: URL
    private let secrets: SecretStoring
    private let keyAccount: String

    init(rootDirectory: URL, secrets: SecretStoring = KeychainStore()) {
        directory = rootDirectory.appendingPathComponent("resume", isDirectory: true)
        self.secrets = secrets
        let namespace = SHA256.hash(data: Data(rootDirectory.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        keyAccount = "download-resume-key.\(namespace)"
    }

    func save(_ data: Data, envelope: DownloadTaskEnvelope) throws -> String? {
        guard !data.isEmpty else { return nil }
        let reference = UUID().uuidString.lowercased()
        let sealed = try AES.GCM.seal(data, using: key(), authenticating: ownership(envelope))
        guard let bytes = sealed.combined else { throw KeychainError.invalidData }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try? root.setResourceValues(attributes)
        try bytes.write(to: directory.appendingPathComponent(reference),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return reference
    }

    func load(_ reference: String, envelope: DownloadTaskEnvelope) throws -> Data? {
        guard UUID(uuidString: reference) != nil else { throw KeychainError.invalidData }
        let url = directory.appendingPathComponent(reference)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw KeychainError.invalidData
        }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        return try AES.GCM.open(box, using: key(), authenticating: ownership(envelope))
    }

    func remove(_ reference: String?) throws {
        guard let reference, UUID(uuidString: reference) != nil else { return }
        let url = directory.appendingPathComponent(reference)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func key() throws -> SymmetricKey {
        if let encoded = try secrets.read(account: keyAccount) {
            guard let bytes = Data(base64Encoded: encoded), bytes.count == 32 else { throw KeychainError.invalidData }
            return SymmetricKey(data: bytes)
        }
        let key = SymmetricKey(size: .bits256)
        try secrets.write(key.withUnsafeBytes { Data($0).base64EncodedString() }, account: keyAccount)
        return key
    }

    private func ownership(_ envelope: DownloadTaskEnvelope) -> Data {
        // Transfer UUID deliberately excluded: a resumed transfer gets a fresh
        // callback identity while remaining the same job and selected resource.
        let values = [ServerIdentity.canonical(envelope.metadata.serverOrigin),
                      envelope.metadata.accountUsername ?? "", envelope.metadata.recordID.uuidString,
                      envelope.metadata.attemptID?.uuidString ?? "", envelope.resourceID]
        return (try? JSONEncoder().encode(values)) ?? Data()
    }
}
