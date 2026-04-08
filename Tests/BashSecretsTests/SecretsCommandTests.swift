import Foundation
import Testing
import Bash

#if Secrets

@Suite("Secrets Command")
struct SecretsCommandTests {
    @Test("secrets command is disabled until a provider is enabled")
    func secretsCommandIsDisabledUntilProviderIsEnabled() async throws {
        let root = try SecretsTestSupport.makeTempDirectory(prefix: "BashSecretsTests-Disabled")
        defer { SecretsTestSupport.removeDirectory(root) }

        let session = try await BashSession(
            rootDirectory: root,
            options: SessionOptions(filesystem: ReadWriteFilesystem(), layout: .unixLike)
        )

        let missing = await session.run("secrets --help")
        #expect(missing.exitCode == 127)

        await session.enableSecrets(provider: InMemorySecretsProvider())

        let available = await session.run("secrets --help")
        #expect(available.exitCode == 0)
        #expect(available.stdoutString.contains("USAGE: secrets"))
    }

    @Test("help output and subcommand help")
    func helpOutputAndSubcommandHelp() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let help = await session.run("secrets --help")
        #expect(help.exitCode == 0)
        #expect(help.stdoutString.contains("USAGE: secrets"))
        #expect(!help.stdoutString.contains("\n  ref"))

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
        #expect(reference.hasPrefix("secretref:"))

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

    @Test("delete flow uses references only")
    func deleteFlowUsesReferencesOnly() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"

        let put = await session.run(
            "secrets put --service \(service) --account \(account)",
            stdin: Data("value".utf8)
        )
        #expect(put.exitCode == 0)

        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let missingDelimiter = await session.run("secrets run --env API_TOKEN=secretref:abc printenv API_TOKEN")
        #expect(missingDelimiter.exitCode == 2)
        #expect(missingDelimiter.stderrString.contains("expected --env or --"))

        let missingBinding = await session.run("secrets run -- printenv API_TOKEN")
        #expect(missingBinding.exitCode == 2)
        #expect(missingBinding.stderrString.contains("at least one --env binding"))
    }

    @Test("provider API resolves references without shell output")
    func providerAPIResolvesReferencesWithoutShellOutput() async throws {
        let provider = InMemorySecretsProvider()
        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let secret = Data("api-secret-\(UUID().uuidString)".utf8)

        let reference = try await provider.putGenericPassword(
            service: service,
            account: account,
            value: secret
        )
        #expect(reference.hasPrefix("secretref:"))

        let metadata = try await provider.metadata(forReference: reference)
        #expect(metadata.locator.service == service)
        #expect(metadata.locator.account == account)

        let resolved = try await provider.resolveReference(reference)
        #expect(resolved == secret)

        let deleted = try await provider.deleteReference(reference)
        #expect(deleted)
    }

    @Test("malformed references are rejected")
    func malformedReferencesAreRejected() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let invalidGet = await session.run("secrets get secretref:not-a-valid-reference")
        #expect(invalidGet.exitCode == 2)
        #expect(invalidGet.stderrString.contains("invalid secret reference"))

        let invalidDelete = await session.run("secrets delete secretref:###")
        #expect(invalidDelete.exitCode == 2)
        #expect(invalidDelete.stderrString.contains("invalid secret reference"))
    }

    @Test("strict policy blocks secrets get --reveal")
    func strictPolicyBlocksReveal() async throws {
        let (session, root) = try await SecretsTestSupport.makeSecretAwareSession(policy: .strict)
        defer { SecretsTestSupport.removeDirectory(root) }

        let put = await session.run(
            "secrets put --service strict-service --account strict-account",
            stdin: Data("strict-secret".utf8)
        )
        #expect(put.exitCode == 0)
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let reveal = await session.run("secrets get --reveal \(reference)")
        #expect(reveal.exitCode == 2)
        #expect(reveal.stderrString.contains("blocked by strict secret policy"))
    }

    @Test("resolve and redact policy masks command output")
    func resolveAndRedactPolicyMasksOutput() async throws {
        let (session, root) = try await SecretsTestSupport.makeSecretAwareSession(policy: .resolveAndRedact)
        defer { SecretsTestSupport.removeDirectory(root) }

        let secretValue = "masked-secret-\(UUID().uuidString)"
        let put = await session.run(
            "secrets put --service masked-service --account masked-account",
            stdin: Data(secretValue.utf8)
        )
        #expect(put.exitCode == 0)
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let run = await session.run("secrets run --env API_TOKEN=\(reference) -- printenv API_TOKEN")
        #expect(run.exitCode == 0)
        #expect(run.stdoutString == "\(reference)\n")
        #expect(!run.stdoutString.contains(secretValue))
    }

    @Test("provider can be shared across sessions for durable refs")
    func providerCanBeSharedAcrossSessionsForDurableRefs() async throws {
        let provider = InMemorySecretsProvider()
        let root1 = try SecretsTestSupport.makeTempDirectory(prefix: "BashSecretsTests-A")
        let root2 = try SecretsTestSupport.makeTempDirectory(prefix: "BashSecretsTests-B")
        defer {
            SecretsTestSupport.removeDirectory(root1)
            SecretsTestSupport.removeDirectory(root2)
        }

        let session1 = try await SecretsTestSupport.makeSecretAwareSession(
            provider: provider,
            policy: .resolveAndRedact,
            root: root1
        )
        let session2 = try await SecretsTestSupport.makeSecretAwareSession(
            provider: provider,
            policy: .resolveAndRedact,
            root: root2
        )

        let put = await session1.run(
            "secrets put --service shared-service --account shared-account",
            stdin: Data("shared-secret".utf8)
        )
        #expect(put.exitCode == 0)
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let get = await session2.run("secrets get \(reference)")
        #expect(get.exitCode == 0)
        #expect(get.stdoutString.contains("service=shared-service"))
    }

    @Test("references are scoped to their provider")
    func referencesAreScopedToTheirProvider() async throws {
        let providerA = InMemorySecretsProvider()
        let providerB = InMemorySecretsProvider()
        let (sessionA, rootA) = try await SecretsTestSupport.makeSecretAwareSession(
            provider: providerA,
            policy: .resolveAndRedact
        )
        let (sessionB, rootB) = try await SecretsTestSupport.makeSecretAwareSession(
            provider: providerB,
            policy: .resolveAndRedact
        )
        defer {
            SecretsTestSupport.removeDirectory(rootA)
            SecretsTestSupport.removeDirectory(rootB)
        }

        let put = await sessionA.run(
            "secrets put --service scoped-service --account scoped-account",
            stdin: Data("scoped-secret".utf8)
        )
        #expect(put.exitCode == 0)
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let get = await sessionB.run("secrets get \(reference)")
        #expect(get.exitCode == 2)
        #expect(get.stderrString.contains("invalid secret reference"))
    }

    @Test("keychain scope keeps service and account entries isolated")
    func keychainScopeKeepsEntriesIsolated() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let keychainA = "scope-A"
        let keychainB = "scope-B"
        let secretA = "secret-A-\(UUID().uuidString)"
        let secretB = "secret-B-\(UUID().uuidString)"

        let putA = await session.run(
            "secrets put --service \(service) --account \(account) --keychain \(keychainA)",
            stdin: Data(secretA.utf8)
        )
        #expect(putA.exitCode == 0)
        let referenceA = putA.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let putB = await session.run(
            "secrets put --service \(service) --account \(account) --keychain \(keychainB)",
            stdin: Data(secretB.utf8)
        )
        #expect(putB.exitCode == 0)
        let referenceB = putB.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(referenceA != referenceB)

        let getA = await session.run("secrets get --reveal \(referenceA)")
        #expect(getA.exitCode == 0)
        #expect(getA.stdoutString == secretA)

        let getB = await session.run("secrets get --reveal \(referenceB)")
        #expect(getB.exitCode == 0)
        #expect(getB.stdoutString == secretB)
    }

    @Test("json output payloads are structured and complete")
    func jsonOutputPayloadsAreStructuredAndComplete() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"
        let keychain = "scope-json"
        let label = "api token"

        let put = await session.run(
            "secrets put --service \(service) --account \(account) --keychain \(keychain) --label '\(label)' --json",
            stdin: Data("json-secret".utf8)
        )
        #expect(put.exitCode == 0)
        let putPayload: PutJSONPayload = try decodeJSON(put.stdoutString)
        #expect(putPayload.service == service)
        #expect(putPayload.account == account)
        #expect(putPayload.keychain == keychain)
        #expect(!putPayload.updated)
        #expect(putPayload.reference.hasPrefix("secretref:"))

        let get = await session.run("secrets get \(putPayload.reference) --json")
        #expect(get.exitCode == 0)
        let getPayload: GetJSONPayload = try decodeJSON(get.stdoutString)
        #expect(getPayload.reference == putPayload.reference)
        #expect(getPayload.service == service)
        #expect(getPayload.account == account)
        #expect(getPayload.keychain == keychain)
        #expect(getPayload.label == label)
    }

    @Test("put update and delete force behavior")
    func putUpdateAndDeleteForceBehavior() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let service = "svc-\(UUID().uuidString)"
        let account = "acct-\(UUID().uuidString)"

        let first = await session.run(
            "secrets put --service \(service) --account \(account)",
            stdin: Data("first-value".utf8)
        )
        #expect(first.exitCode == 0)
        let reference = first.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let duplicate = await session.run(
            "secrets put --service \(service) --account \(account)",
            stdin: Data("second-value".utf8)
        )
        #expect(duplicate.exitCode == 1)
        #expect(duplicate.stderrString.contains("already exists"))

        let update = await session.run(
            "secrets put --service \(service) --account \(account) --update",
            stdin: Data("second-value".utf8)
        )
        #expect(update.exitCode == 0)

        let reveal = await session.run("secrets get --reveal \(reference)")
        #expect(reveal.exitCode == 0)
        #expect(reveal.stdoutString == "second-value")

        let delete = await session.run("secrets delete \(reference)")
        #expect(delete.exitCode == 0)

        let forceMissing = await session.run("secrets delete --force \(reference)")
        #expect(forceMissing.exitCode == 0)

        let missing = await session.run("secrets delete \(reference)")
        #expect(missing.exitCode == 1)
        #expect(missing.stderrString.contains("not found"))
    }

    @Test("shell access to existing secrets is ref only")
    func shellAccessToExistingSecretsIsRefOnly() async throws {
        let (session, root) = try await SecretsTestSupport.makeSession()
        defer { SecretsTestSupport.removeDirectory(root) }

        let get = await session.run("secrets get --service app --account api")
        #expect(get.exitCode != 0)
        #expect(get.stderrString.contains("--service"))

        let delete = await session.run("secrets delete --service app --account api")
        #expect(delete.exitCode != 0)
        #expect(delete.stderrString.contains("--service"))
    }

    @Test("run rejects non-UTF8 secrets when injecting env vars")
    func runRejectsNonUTF8SecretsWhenInjectingEnvVars() async throws {
        let provider = InMemorySecretsProvider()
        let (session, root) = try await SecretsTestSupport.makeSession(provider: provider)
        defer { SecretsTestSupport.removeDirectory(root) }

        let reference = try await provider.putGenericPassword(
            service: "bin-\(UUID().uuidString)",
            account: "blob-\(UUID().uuidString)",
            value: Data([0xFF, 0x00, 0xFE])
        )

        let run = await session.run("secrets run --env BINARY=\(reference) -- printenv BINARY")
        #expect(run.exitCode == 1)
        #expect(run.stderrString.contains("not UTF-8"))
    }

    @Test("protected mode redacts caller output but not redirected files")
    func protectedModeRedactsCallerOutputButNotRedirectedFiles() async throws {
        let (session, root) = try await SecretsTestSupport.makeSecretAwareSession(policy: .resolveAndRedact)
        defer { SecretsTestSupport.removeDirectory(root) }

        let secretValue = "secret-\(UUID().uuidString)"
        let put = await session.run(
            "secrets put --service redact-service --account redact-account",
            stdin: Data(secretValue.utf8)
        )
        #expect(put.exitCode == 0)
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let stderrRun = await session.run("secrets run --env TOKEN=\(reference) -- \(secretValue)")
        #expect(stderrRun.exitCode == 127)
        #expect(stderrRun.stderrString.contains("\(reference): command not found"))
        #expect(!stderrRun.stderrString.contains(secretValue))

        let pipeline = await session.run("secrets run --env TOKEN=\(reference) -- printenv TOKEN | cat")
        #expect(pipeline.exitCode == 0)
        #expect(pipeline.stdoutString == "\(reference)\n")
        #expect(!pipeline.stdoutString.contains(secretValue))

        let stdoutRedirect = await session.run("secrets run --env TOKEN=\(reference) -- printenv TOKEN > token.txt")
        #expect(stdoutRedirect.exitCode == 0)
        #expect(stdoutRedirect.stdoutString.isEmpty)
        let tokenFile = await session.run("cat token.txt")
        #expect(tokenFile.exitCode == 0)
        #expect(tokenFile.stdoutString == "\(secretValue)\n")

        let stderrRedirect = await session.run("secrets run --env TOKEN=\(reference) -- \(secretValue) 2> error.txt")
        #expect(stderrRedirect.exitCode == 127)
        #expect(stderrRedirect.stderrString.isEmpty)
        let errorFile = await session.run("cat error.txt")
        #expect(errorFile.exitCode == 0)
        #expect(errorFile.stdoutString.contains("\(secretValue): command not found"))
    }

    @Test("export and expansion keep opaque references")
    func exportAndExpansionKeepOpaqueReferences() async throws {
        let (session, root) = try await SecretsTestSupport.makeSecretAwareSession(policy: .resolveAndRedact)
        defer { SecretsTestSupport.removeDirectory(root) }

        let put = await session.run(
            "secrets put --service export-service --account export-account",
            stdin: Data("export-secret".utf8)
        )
        #expect(put.exitCode == 0)
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let export = await session.run("export TOKEN=\(reference)")
        #expect(export.exitCode == 0)

        let printenv = await session.run("printenv TOKEN")
        #expect(printenv.exitCode == 0)
        #expect(printenv.stdoutString == "\(reference)\n")

        let echo = await session.run("echo $TOKEN")
        #expect(echo.exitCode == 0)
        #expect(echo.stdoutString == "\(reference)\n")
    }

    @Test("curl resolves secret refs and redacts verbose output")
    func curlResolvesSecretRefsAndRedactsVerboseOutput() async throws {
        let (session, root) = try await SecretsTestSupport.makeSecretAwareSession(
            policy: .resolveAndRedact,
            networkPolicy: .unrestricted
        )
        defer { SecretsTestSupport.removeDirectory(root) }

        let secretValue = "curl-secret-\(UUID().uuidString)"
        let put = await session.run(
            "secrets put --service curl-service --account curl-account",
            stdin: Data(secretValue.utf8)
        )
        #expect(put.exitCode == 0)
        let reference = put.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

        let curl = await session.run(
            "curl -v --connect-timeout 0.1 -H 'Authorization: Bearer \(reference)' https://127.0.0.1:1"
        )
        #expect(curl.exitCode != 0)
        #expect(curl.stderrString.contains("Authorization: Bearer \(reference)"))
        #expect(!curl.stderrString.contains(secretValue))
    }

    private func decodeJSON<T: Decodable>(_ output: String) throws -> T {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(trimmed.utf8)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct PutJSONPayload: Decodable {
        var reference: String
        var service: String
        var account: String
        var keychain: String?
        var updated: Bool
    }

    private struct GetJSONPayload: Decodable {
        var reference: String
        var service: String
        var account: String
        var keychain: String?
        var label: String?
    }
}

#endif
