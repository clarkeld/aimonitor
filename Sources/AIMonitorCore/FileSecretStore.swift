import Foundation

public final class FileSecretStore: SecretStoring, @unchecked Sendable {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = (try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? FileManager.default.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent("AIMonitor", isDirectory: true)
                .appendingPathComponent("secrets.json")
        }
    }

    public func read(provider: Provider) throws -> String? {
        try load()[provider.rawValue]
    }

    public func save(_ value: String, provider: Provider) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var secrets = try load()
        secrets[provider.rawValue] = value
        let data = try encoder.encode(secrets)
        try data.write(to: fileURL, options: .atomic)
        try setOwnerOnlyPermissions()
    }

    public func delete(provider: Provider) throws {
        var secrets = try load()
        secrets.removeValue(forKey: provider.rawValue)
        let data = try encoder.encode(secrets)
        try data.write(to: fileURL, options: .atomic)
        try setOwnerOnlyPermissions()
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode([String: String].self, from: data)
    }

    private func setOwnerOnlyPermissions() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }
}
