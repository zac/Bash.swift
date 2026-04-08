import BashTools

extension BashSession {
    func registerCompiledCommands() async {
        for command in BashCompiledCommands.all() {
            await register(command)
        }
    }
}
