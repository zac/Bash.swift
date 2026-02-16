#if canImport(Security)
import Foundation
import Security

public struct AppleKeychainSecretsRuntime: SecretsRuntime {
    public init() {}

    public func putGenericPassword(
        locator: SecretLocator,
        value: Data,
        label: String?,
        update: Bool
    ) async throws {
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
                return
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
            return
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

    public func getGenericPassword(
        locator: SecretLocator,
        revealValue: Bool
    ) async throws -> SecretFetchResult {
        let metadata = try loadMetadata(locator: locator)
        let value: Data?
        if revealValue {
            value = try loadValue(locator: locator)
        } else {
            value = nil
        }
        return SecretFetchResult(metadata: metadata, value: value)
    }

    public func deleteGenericPassword(locator: SecretLocator) async throws -> Bool {
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

        return SecretMetadata(
            locator: SecretLocator(service: service, account: account, keychain: locator.keychain),
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
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: locator.service,
            kSecAttrAccount as String: locator.account,
        ]
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
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return .runtimeFailure("keychain \(operation) failed: \(message) (\(status))")
        }
    }
}
#endif
