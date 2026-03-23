import CryptoKit
import Foundation

public struct SecretLocator: Sendable, Hashable, Codable {
    public var service: String
    public var account: String
    public var keychain: String?

    public init(service: String, account: String, keychain: String? = nil) {
        self.service = service
        self.account = account
        self.keychain = keychain
    }
}

enum SecretReference {
    static let prefix = "secretref:"

    static func makeGenericPasswordReference(
        locator: SecretLocator,
        using key: SymmetricKey
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(Payload(kind: "generic-password", locator: locator))
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else {
            throw SecretsError.runtimeFailure("failed to create secret reference")
        }
        return prefix + combined.base64URLEncodedString()
    }

    static func parseGenericPasswordReference(
        _ value: String,
        using key: SymmetricKey
    ) throws -> SecretLocator {
        guard value.hasPrefix(prefix) else {
            throw SecretsError.invalidReference(value)
        }

        let rawPayload = String(value.dropFirst(prefix.count))
        guard let sealedData = Data(base64URLEncoded: rawPayload) else {
            throw SecretsError.invalidReference(value)
        }

        let payloadData: Data
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: sealedData)
            payloadData = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw SecretsError.invalidReference(value)
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: payloadData)
            guard payload.kind == "generic-password" else {
                throw SecretsError.invalidReference(value)
            }
            return payload.locator
        } catch let error as SecretsError {
            throw error
        } catch {
            throw SecretsError.invalidReference(value)
        }
    }

    private struct Payload: Codable {
        let kind: String
        let locator: SecretLocator
    }
}

extension SymmetricKey {
    var rawData: Data {
        withUnsafeBytes { Data($0) }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded value: String) {
        var normalized = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }

        self.init(base64Encoded: normalized)
    }
}
