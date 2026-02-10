import Bash

public extension BashSession {
    func registerPython() async {
        await register(Python3Command.self)
    }

    func registerPython3() async {
        await register(Python3Command.self)
    }
}
