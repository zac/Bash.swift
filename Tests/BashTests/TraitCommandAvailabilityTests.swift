import Testing
import Bash

#if !Git && !Python && !SQLite && !Secrets
@Suite("Trait Command Availability")
struct TraitCommandAvailabilityTests {
    @Test("optional commands are unavailable without traits")
    func optionalCommandsAreUnavailableWithoutTraits() async throws {
        let (session, root) = try await TestSupport.makeSession()
        defer { TestSupport.removeDirectory(root) }

        for command in ["git", "python3", "sqlite3", "secrets"] {
            let result = await session.run("\(command) --help")
            #expect(result.exitCode == 127, "\(command) should not be registered")
            #expect(result.stderrString.contains("\(command): command not found"))
        }
    }
}
#endif
