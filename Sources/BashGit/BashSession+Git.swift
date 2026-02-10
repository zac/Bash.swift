import Bash

public extension BashSession {
    func registerGit() async {
        await register(GitCommand.self)
    }
}
