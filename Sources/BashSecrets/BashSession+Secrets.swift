import Bash

public extension BashSession {
    func registerSecrets() async {
        await register(SecretsCommand.self)
    }
}
