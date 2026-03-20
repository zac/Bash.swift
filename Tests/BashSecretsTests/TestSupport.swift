import Foundation
import Bash
import BashSecrets

enum SecretsTestSupport {
    static func makeTempDirectory(prefix: String = "BashSecretsTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeSession(
        options: SessionOptions = SessionOptions(filesystem: ReadWriteFilesystem(), layout: .unixLike)
    ) async throws -> (session: BashSession, root: URL) {
        await Secrets.setRuntime(InMemorySecretsRuntime.shared)
        let root = try makeTempDirectory()
        let session = try await BashSession(rootDirectory: root, options: options)
        await session.registerSecrets()
        return (session, root)
    }

    static func makeSecretAwareSession(
        policy: SecretHandlingPolicy,
        networkPolicy: NetworkPolicy = .disabled
    ) async throws -> (session: BashSession, root: URL) {
        try await makeSession(
            options: SessionOptions(
                filesystem: ReadWriteFilesystem(),
                layout: .unixLike,
                networkPolicy: networkPolicy,
                secretPolicy: policy,
                secretResolver: BashSecretsReferenceResolver()
            )
        )
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

actor InMemorySecretsRuntime: SecretsRuntime {
    static let shared = InMemorySecretsRuntime()

    private struct StoredValue {
        var metadata: SecretMetadata
        var value: Data
    }

    private var values: [SecretLocator: StoredValue] = [:]

    func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws {
        if values[locator] != nil, !update {
            throw SecretsError.duplicateItem(locator)
        }

        values[locator] = StoredValue(
            metadata: SecretMetadata(locator: locator, label: label),
            value: value
        )
    }

    func getGenericPassword(
        locator: SecretLocator,
        revealValue: Bool
    ) async throws -> SecretFetchResult {
        guard let stored = values[locator] else {
            throw SecretsError.notFound(locator)
        }

        return SecretFetchResult(
            metadata: stored.metadata,
            value: revealValue ? stored.value : nil
        )
    }

    func deleteGenericPassword(locator: SecretLocator) async throws -> Bool {
        values.removeValue(forKey: locator) != nil
    }
}
