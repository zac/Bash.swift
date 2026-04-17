import Foundation
import Bash

#if Secrets

enum SecretsTestSupport {
    static func makeTempDirectory(prefix: String = "BashSecretsTests") throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = base.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeSession(
        provider: InMemorySecretsProvider = InMemorySecretsProvider(),
        options: SessionOptions = SessionOptions(filesystem: ReadWriteFilesystem(), layout: .unixLike)
    ) async throws -> (session: BashSession, root: URL) {
        let root = try makeTempDirectory()
        let session = try await BashSession(rootDirectory: root, options: options)
        await session.enableSecrets(provider: provider)
        return (session, root)
    }

    static func makeSecretAwareSession(
        provider: InMemorySecretsProvider = InMemorySecretsProvider(),
        policy: SecretHandlingPolicy,
        networkPolicy: ShellNetworkPolicy = .disabled
    ) async throws -> (session: BashSession, root: URL) {
        let root = try makeTempDirectory()
        let session = try await makeSecretAwareSession(
            provider: provider,
            policy: policy,
            networkPolicy: networkPolicy,
            root: root
        )
        return (session, root)
    }

    static func makeSecretAwareSession(
        provider: InMemorySecretsProvider = InMemorySecretsProvider(),
        policy: SecretHandlingPolicy,
        networkPolicy: ShellNetworkPolicy = .disabled,
        root: URL
    ) async throws -> BashSession {
        let session = try await BashSession(
            rootDirectory: root,
            options: SessionOptions(
                filesystem: ReadWriteFilesystem(),
                layout: .unixLike,
                networkPolicy: networkPolicy
            )
        )
        await session.enableSecrets(provider: provider, policy: policy)
        return session
    }

    static func removeDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

#endif
