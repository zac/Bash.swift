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

public protocol SecretsProvider: Sendable {
    func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws -> String

    func reference(for locator: SecretLocator) async throws -> String

    func getGenericPassword(
        reference: String,
        revealValue: Bool
    ) async throws -> SecretFetchResult

    func deleteReference(_ reference: String) async throws -> Bool
}

public extension SecretsProvider {
    func putGenericPassword(
        service: String,
        account: String,
        keychain: String? = nil,
        value: Data,
        label: String? = nil,
        update: Bool = true
    ) async throws -> String {
        try await putGenericPassword(
            locator: SecretLocator(service: service, account: account, keychain: keychain),
            value: value,
            label: label,
            update: update
        )
    }

    func reference(
        service: String,
        account: String,
        keychain: String? = nil
    ) async throws -> String {
        try await reference(
            for: SecretLocator(service: service, account: account, keychain: keychain)
        )
    }

    func metadata(forReference reference: String) async throws -> SecretMetadata {
        try await getGenericPassword(reference: reference, revealValue: false).metadata
    }

    func resolveReference(_ reference: String) async throws -> Data {
        let fetched = try await getGenericPassword(reference: reference, revealValue: true)
        guard let value = fetched.value else {
            let locator = fetched.metadata.locator
            throw SecretsError.runtimeFailure(
                "secret value missing for service '\(locator.service)' and account '\(locator.account)'"
            )
        }
        return value
    }
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

struct UnsupportedSecretsProvider: SecretsProvider {
    let message: String

    func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws -> String {
        _ = locator
        _ = value
        _ = label
        _ = update
        throw SecretsError.unsupported(message)
    }

    func reference(for locator: SecretLocator) async throws -> String {
        _ = locator
        throw SecretsError.unsupported(message)
    }

    func getGenericPassword(
        reference: String,
        revealValue: Bool
    ) async throws -> SecretFetchResult {
        _ = reference
        _ = revealValue
        throw SecretsError.unsupported(message)
    }

    func deleteReference(_ reference: String) async throws -> Bool {
        _ = reference
        throw SecretsError.unsupported(message)
    }
}
