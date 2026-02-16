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

public struct SecretReference: Sendable, Hashable, Codable {
    public static let prefix = "secretref:v1:"

    public var locator: SecretLocator

    public init(locator: SecretLocator) {
        self.locator = locator
    }

    public var stringValue: String {
        let payload = Payload(kind: "generic-password", locator: locator)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let encoded = try? encoder.encode(payload)
        else {
            return Self.prefix
        }

        return Self.prefix + encoded.base64URLEncodedString()
    }

    public init?(string: String) {
        guard string.hasPrefix(Self.prefix) else {
            return nil
        }

        let rawPayload = String(string.dropFirst(Self.prefix.count))
        guard
            let payloadData = Data(base64URLEncoded: rawPayload),
            let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
            payload.kind == "generic-password"
        else {
            return nil
        }

        locator = payload.locator
    }

    private struct Payload: Codable {
        let kind: String
        let locator: SecretLocator
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
