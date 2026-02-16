import Foundation
import Testing
import Bash
import BashSecrets

@Suite("Secrets Command")
struct SecretsCommandTests {
    @Test("help output and subcommand help")
    func helpOutputAndSubcommandHelp() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let help = await session.run("secrets --help")
        #expect(help.exitCode == 0)
        #expect(help.stdoutString.contains("USAGE: secrets"))

        let subcommandHelp = await session.run("secrets put --help")
        #expect(subcommandHelp.exitCode == 0)
        #expect(subcommandHelp.stdoutString.contains("USAGE: secrets put"))
    }

    @Test("put and get metadata without revealing secret")
    func putAndGetMetadataWithoutRevealingSecret() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let secret = "top-secret-value-\(UUID().uuidString)"

        let put = await session.run(
            "secrets put --service \(service) --account \(account)",
            stdin: Data(secret.utf8)
        )
        #expect(put.exitCode == 0)

        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reference.hasPrefix("secretref:v1:"))

        let get = await session.run("secrets get \(reference)")
        #expect(get.exitCode == 0)
        #expect(get.stdoutString.contains("service=\(service)"))
        #expect(get.stdoutString.contains("account=\(account)"))
        #expect(get.stdoutString.contains("reference=\(reference)"))
        #expect(!get.stdoutString.contains(secret))
    }

    @Test("get reveal prints secret value")
    func getRevealPrintsSecretValue() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let secret = "reveal-\(UUID().uuidString)"

        let put = await session.run(
            "secrets put --service \(service) --account \(account)",
            stdin: Data(secret.utf8)
        )
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let reveal = await session.run("secrets get --reveal \(reference)")
        #expect(reveal.exitCode == 0)
        #expect(reveal.stdoutString == secret)
    }

    @Test("ref and delete flow")
    func refAndDeleteFlow() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"

        _ = await session.run(
            "secrets put --service \(service) --account \(account)",
            stdin: Data("value".utf8)
        )

        let ref = await session.run("secrets ref --service \(service) --account \(account)")
        #expect(ref.exitCode == 0)
        let reference = ref.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(reference.hasPrefix("secretref:v1:"))

        let delete = await session.run("secrets delete \(reference)")
        #expect(delete.exitCode == 0)

        let missing = await session.run("secrets get \(reference)")
        #expect(missing.exitCode != 0)
        #expect(missing.stderrString.contains("not found"))
    }

    @Test("run injects referenced secrets for one command only")
    func runInjectsReferencedSecretsForOneCommandOnly() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let secret = "token-\(UUID().uuidString)"

        let put = await session.run(
            "secrets put --service \(service) --account \(account)",
            stdin: Data(secret.utf8)
        )
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let run = await session.run("secrets run --env API_TOKEN=\(reference) -- printenv API_TOKEN")
        #expect(run.exitCode == 0)
        #expect(run.stdoutString == "\(secret)\n")

        let after = await session.run("printenv API_TOKEN")
        #expect(after.exitCode == 1)
    }

    @Test("run requires env bindings and delimiter")
    func runRequiresBindingsAndDelimiter() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let missingDelimiter = await session.run("secrets run --env API_TOKEN=secretref:v1:abc printenv API_TOKEN")
        #expect(missingDelimiter.exitCode == 2)
        #expect(missingDelimiter.stderrString.contains("expected --env or --"))

        let missingBinding = await session.run("secrets run -- printenv API_TOKEN")
        #expect(missingBinding.exitCode == 2)
        #expect(missingBinding.stderrString.contains("at least one --env binding"))
    }

    @Test("Secrets API resolves references without shell output")
    func secretsAPIResolvesReferencesWithoutShellOutput() async throws {
        await Secrets.setRuntime(InMemorySecretsRuntime.shared)

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let secret = Data("api-secret-\(UUID().uuidString)".utf8)

        let reference = try await Secrets.putGenericPassword(
            service: service,
            account: account,
            value: secret
        )
        #expect(reference.hasPrefix("secretref:v1:"))

        let metadata = try await Secrets.metadata(forReference: reference)
        #expect(metadata.locator.service == service)
        #expect(metadata.locator.account == account)

        let resolved = try await Secrets.resolveReference(reference)
        #expect(resolved == secret)

        let deleted = try await Secrets.deleteReference(reference)
        #expect(deleted)
    }
}
