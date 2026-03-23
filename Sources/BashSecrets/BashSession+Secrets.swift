import Bash

public extension BashSession {
    func registerSecrets(
        provider: any SecretsProvider,
        policy: SecretHandlingPolicy? = nil,
        redactor: (any SecretOutputRedacting)? = nil
    ) async {
        await register(SecretsCommand.command(provider: provider))
        setSecretResolver(BashSecretsReferenceResolver(provider: provider))
        if let policy {
            setSecretHandlingPolicy(policy)
        }
        if let redactor {
            setSecretOutputRedactor(redactor)
        }
    }
}
