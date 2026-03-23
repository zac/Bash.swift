import CryptoKit
import Foundation

public actor InMemorySecretsProvider: SecretsProvider {
    private struct StoredValue {
        var metadata: SecretMetadata
        var value: Data
    }

    private let referenceKey: SymmetricKey
    private var values: [SecretLocator: StoredValue] = [:]

    public init(referenceKey: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.referenceKey = referenceKey
    }

    public func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws -> String {
        if values[locator] != nil, !update {
            throw SecretsError.duplicateItem(locator)
        }

        values[locator] = StoredValue(
            metadata: SecretMetadata(locator: locator, label: label),
            value: value
        )
        return try issueReference(for: locator)
    }

    public func reference(for locator: SecretLocator) async throws -> String {
        guard values[locator] != nil else {
            throw SecretsError.notFound(locator)
        }
        return try issueReference(for: locator)
    }

    public func getGenericPassword(
        reference: String,
        revealValue: Bool
    ) async throws -> SecretFetchResult {
        let locator = try SecretReference.parseGenericPasswordReference(reference, using: referenceKey)
        guard let stored = values[locator] else {
            throw SecretsError.notFound(locator)
        }

        return SecretFetchResult(
            metadata: stored.metadata,
            value: revealValue ? stored.value : nil
        )
    }

    public func deleteReference(_ reference: String) async throws -> Bool {
        let locator = try SecretReference.parseGenericPasswordReference(reference, using: referenceKey)
        return values.removeValue(forKey: locator) != nil
    }

    private func issueReference(for locator: SecretLocator) throws -> String {
        try SecretReference.makeGenericPasswordReference(locator: locator, using: referenceKey)
    }
}
