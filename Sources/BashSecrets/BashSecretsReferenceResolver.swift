import Foundation
import Bash

public struct BashSecretsReferenceResolver: SecretReferenceResolving {
    public let provider: any SecretsProvider

    public init(provider: any SecretsProvider) {
        self.provider = provider
    }

    public func resolveSecretReference(_ reference: String) async throws -> Data {
        try await provider.resolveReference(reference)
    }
}
