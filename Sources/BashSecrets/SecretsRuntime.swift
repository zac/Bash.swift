import Foundation

public struct SecretMetadata: Sendable, Hashable {
    public var locator: SecretLocator
    public var label: String?

    public init(locator: SecretLocator, label: String? = nil) {
        self.locator = locator
        self.label = label
    }
}

public struct SecretFetchResult: Sendable {
    public var metadata: SecretMetadata
    public var value: Data?

    public init(metadata: SecretMetadata, value: Data? = nil) {
        self.metadata = metadata
        self.value = value
    }
}

public protocol SecretsRuntime: Sendable {
    func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws

    func getGenericPassword(
        locator: SecretLocator,
        revealValue: Bool
    ) async throws -> SecretFetchResult

    func deleteGenericPassword(locator: SecretLocator) async throws -> Bool
}

public enum SecretsError: Error, CustomStringConvertible, Sendable {
    case invalidInput(String)
    case invalidReference(String)
    case notFound(SecretLocator)
    case duplicateItem(SecretLocator)
    case unsupported(String)
    case runtimeFailure(String)

    public var description: String {
        switch self {
        case let .invalidInput(message):
            return message
        case let .invalidReference(value):
            return "invalid secret reference: \(value)"
        case let .notFound(locator):
            return "secret not found for service '\(locator.service)' and account '\(locator.account)'"
        case let .duplicateItem(locator):
            return "secret already exists for service '\(locator.service)' and account '\(locator.account)'"
        case let .unsupported(message):
            return message
        case let .runtimeFailure(message):
            return message
        }
    }
}

public actor SecretsRuntimeRegistry {
    public static let shared = SecretsRuntimeRegistry()

    private var runtime: any SecretsRuntime

    public init(runtime: (any SecretsRuntime)? = nil) {
        if let runtime {
            self.runtime = runtime
            return
        }

        #if canImport(Security)
        self.runtime = AppleKeychainSecretsRuntime()
        #else
        self.runtime = UnsupportedSecretsRuntime(
            message: "keychain secrets are not supported on this platform"
        )
        #endif
    }

    public func setRuntime(_ runtime: any SecretsRuntime) {
        self.runtime = runtime
    }

    public func currentRuntime() -> any SecretsRuntime {
        runtime
    }

    public func resetToDefault() {
        #if canImport(Security)
        runtime = AppleKeychainSecretsRuntime()
        #else
        runtime = UnsupportedSecretsRuntime(
            message: "keychain secrets are not supported on this platform"
        )
        #endif
    }
}

public enum Secrets {
    public static func setRuntime(_ runtime: any SecretsRuntime) async {
        await SecretsRuntimeRegistry.shared.setRuntime(runtime)
    }

    public static func resetRuntime() async {
        await SecretsRuntimeRegistry.shared.resetToDefault()
    }

    public static func makeReference(
        service: String,
        account: String,
        keychain: String? = nil
    ) -> String {
        SecretReference(
            locator: SecretLocator(service: service, account: account, keychain: keychain)
        ).stringValue
    }

    public static func parseReference(_ value: String) -> SecretLocator? {
        SecretReference(string: value)?.locator
    }

    public static func putGenericPassword(
        service: String,
        account: String,
        keychain: String? = nil,
        value: Data,
        label: String? = nil,
        update: Bool = true
    ) async throws -> String {
        let locator = SecretLocator(service: service, account: account, keychain: keychain)
        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        try await runtime.putGenericPassword(
            locator: locator,
            value: value,
            label: label,
            update: update
        )
        return SecretReference(locator: locator).stringValue
    }

    public static func metadata(forReference reference: String) async throws -> SecretMetadata {
        guard let locator = parseReference(reference) else {
            throw SecretsError.invalidReference(reference)
        }
        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        return try await runtime.getGenericPassword(
            locator: locator,
            revealValue: false
        ).metadata
    }

    public static func resolveReference(_ reference: String) async throws -> Data {
        guard let locator = parseReference(reference) else {
            throw SecretsError.invalidReference(reference)
        }
        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        let fetched = try await runtime.getGenericPassword(locator: locator, revealValue: true)
        guard let value = fetched.value else {
            throw SecretsError.runtimeFailure(
                "secret value missing for service '\(locator.service)' and account '\(locator.account)'"
            )
        }
        return value
    }

    public static func deleteReference(_ reference: String) async throws -> Bool {
        guard let locator = parseReference(reference) else {
            throw SecretsError.invalidReference(reference)
        }
        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        return try await runtime.deleteGenericPassword(locator: locator)
    }
}

struct UnsupportedSecretsRuntime: SecretsRuntime {
    let message: String

    func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws {
        _ = locator
        _ = value
        _ = label
        _ = update
        throw SecretsError.unsupported(message)
    }

    func getGenericPassword(
        locator: SecretLocator,
        revealValue: Bool
    ) async throws -> SecretFetchResult {
        _ = locator
        _ = revealValue
        throw SecretsError.unsupported(message)
    }

    func deleteGenericPassword(locator: SecretLocator) async throws -> Bool {
        _ = locator
        throw SecretsError.unsupported(message)
    }
}
