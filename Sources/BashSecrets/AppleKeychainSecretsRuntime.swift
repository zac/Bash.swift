#if canImport(CryptoKit) && canImport(Security)
import CryptoKit
import Foundation
import Security

public actor AppleKeychainSecretsProvider: SecretsProvider {
    private enum Constants {
        static let referenceKeyService = "dev.velos.BashSecrets.reference-key"
        static let referenceKeyAccount = "v2"
        static let referenceKeyLabel = "BashSecrets reference key"
    }

    private var cachedReferenceKey: SymmetricKey?

    public init() {}

    public func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws -> String {
        let query = baseQuery(locator: locator)
        var attributes: [String: Any] = [
            kSecValueData as String: value,
        ]
        if let label {
            attributes[kSecAttrLabel as String] = label
        }

        if update {
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            switch status {
            case errSecSuccess:
                return try issueReference(for: locator)
            case errSecItemNotFound:
                break
            default:
                throw statusError(
                    status,
                    operation: "update",
                    locator: locator
                )
            }
        }

        var addQuery = query
        for (key, value) in attributes {
            addQuery[key] = value
        }

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return try issueReference(for: locator)
        case errSecDuplicateItem:
            throw SecretsError.duplicateItem(locator)
        default:
            throw statusError(
                addStatus,
                operation: "add",
                locator: locator
            )
        }
    }

    public func reference(for locator: SecretLocator) async throws -> String {
        _ = try loadMetadata(locator: locator)
        return try issueReference(for: locator)
    }

    public func getGenericPassword(
        reference: String,
        revealValue: Bool
    ) async throws -> SecretFetchResult {
        let locator = try locator(forReference: reference)
        let metadata = try loadMetadata(locator: locator)
        let value: Data?
        if revealValue {
            value = try loadValue(locator: locator)
        } else {
            value = nil
        }
        return SecretFetchResult(metadata: metadata, value: value)
    }

    public func deleteReference(_ reference: String) async throws -> Bool {
        let locator = try locator(forReference: reference)
        let query = baseQuery(locator: locator)
        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw statusError(
                status,
                operation: "delete",
                locator: locator
            )
        }
    }

    private func locator(forReference reference: String) throws -> SecretLocator {
        try SecretReference.parseGenericPasswordReference(
            reference,
            using: try referenceKey()
        )
    }

    private func issueReference(for locator: SecretLocator) throws -> String {
        try SecretReference.makeGenericPasswordReference(
            locator: locator,
            using: try referenceKey()
        )
    }

    private func referenceKey() throws -> SymmetricKey {
        if let cachedReferenceKey {
            return cachedReferenceKey
        }

        if let existing = try loadReferenceKeyData() {
            guard existing.count == 32 else {
                throw SecretsError.runtimeFailure("keychain reference key payload is invalid")
            }
            let key = SymmetricKey(data: existing)
            cachedReferenceKey = key
            return key
        }

        let key = SymmetricKey(size: .bits256)
        let keyData = key.rawData
        if try storeReferenceKeyData(keyData) {
            cachedReferenceKey = key
            return key
        }

        if let existing = try loadReferenceKeyData(), existing.count == 32 {
            let sharedKey = SymmetricKey(data: existing)
            cachedReferenceKey = sharedKey
            return sharedKey
        }

        throw SecretsError.runtimeFailure("keychain reference key payload is invalid")
    }

    private func loadReferenceKeyData() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.referenceKeyService,
            kSecAttrAccount as String: Constants.referenceKeyAccount,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue as Any,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let value = item as? Data else {
                throw SecretsError.runtimeFailure("keychain returned a non-data reference key")
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw SecretsError.runtimeFailure(
                "keychain read reference key failed: \(statusMessage(status)) (\(status))"
            )
        }
    }

    private func storeReferenceKeyData(_ data: Data) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Constants.referenceKeyService,
            kSecAttrAccount as String: Constants.referenceKeyAccount,
            kSecAttrLabel as String: Constants.referenceKeyLabel,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return true
        case errSecDuplicateItem:
            return false
        default:
            throw SecretsError.runtimeFailure(
                "keychain write reference key failed: \(statusMessage(status)) (\(status))"
            )
        }
    }

    private func loadMetadata(locator: SecretLocator) throws -> SecretMetadata {
        var query = baseQuery(locator: locator)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = kCFBooleanTrue

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw statusError(
                status,
                operation: "read metadata",
                locator: locator
            )
        }

        guard let attributes = item as? [String: Any] else {
            throw SecretsError.runtimeFailure("keychain returned an invalid metadata payload")
        }

        let service = attributes[kSecAttrService as String] as? String ?? locator.service
        let account = attributes[kSecAttrAccount as String] as? String ?? locator.account
        let label = attributes[kSecAttrLabel as String] as? String
        let scopedKeychain: String?
        if let rawScope = attributes[kSecAttrGeneric as String] as? Data,
           let decodedScope = String(data: rawScope, encoding: .utf8),
           !decodedScope.isEmpty {
            scopedKeychain = decodedScope
        } else {
            scopedKeychain = locator.keychain
        }

        return SecretMetadata(
            locator: SecretLocator(service: service, account: account, keychain: scopedKeychain),
            label: label
        )
    }

    private func loadValue(locator: SecretLocator) throws -> Data {
        var query = baseQuery(locator: locator)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw statusError(
                status,
                operation: "read value",
                locator: locator
            )
        }

        guard let value = item as? Data else {
            throw SecretsError.runtimeFailure("keychain returned a non-data value")
        }
        return value
    }

    private func baseQuery(locator: SecretLocator) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: locator.service,
            kSecAttrAccount as String: locator.account,
        ]

        if let keychain = locator.keychain, !keychain.isEmpty {
            query[kSecAttrGeneric as String] = Data(keychain.utf8)
        }

        return query
    }

    private func statusError(
        _ status: OSStatus,
        operation: String,
        locator: SecretLocator
    ) -> SecretsError {
        switch status {
        case errSecItemNotFound:
            return .notFound(locator)
        case errSecDuplicateItem:
            return .duplicateItem(locator)
        default:
            return .runtimeFailure(
                "keychain \(operation) failed: \(statusMessage(status)) (\(status))"
            )
        }
    }

    private func statusMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}
#else
import Foundation

public struct AppleKeychainSecretsProvider: SecretsProvider {
    public init() {}

    public func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws -> String {
        _ = locator
        _ = value
        _ = label
        _ = update
        throw SecretsError.unsupported("keychain secrets are not supported on this platform")
    }

    public func reference(for locator: SecretLocator) async throws -> String {
        _ = locator
        throw SecretsError.unsupported("keychain secrets are not supported on this platform")
    }

    public func getGenericPassword(
        reference: String,
        revealValue: Bool
    ) async throws -> SecretFetchResult {
        _ = reference
        _ = revealValue
        throw SecretsError.unsupported("keychain secrets are not supported on this platform")
    }

    public func deleteReference(_ reference: String) async throws -> Bool {
        _ = reference
        throw SecretsError.unsupported("keychain secrets are not supported on this platform")
    }
}
#endif
