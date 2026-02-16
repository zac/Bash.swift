import ArgumentParser
import Foundation
import Bash

public struct SecretsCommand: BuiltinCommand {
    public struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "Subcommand")
        public var arguments: [String] = []

        public init() {}
    }

    public static let name = "secrets"
    public static let aliases = ["secret"]
    public static let overview = "Manage keychain-backed secrets using opaque references"

    private static let helpText = """
    OVERVIEW: Manage keychain-backed secrets using opaque references

    USAGE: secrets <subcommand> [options]

    SUBCOMMANDS:
      put      Store or update a secret and emit a secret reference
      ref      Emit a secret reference for an existing secret
      get      Read secret metadata, or reveal value with --reveal
      delete   Delete a secret by locator or reference
      run      Resolve references into env vars for one command

    NOTES:
      - References look like secretref:v1:...
      - Prefer 'put --stdin' to avoid putting secrets in command history.
      - 'get' does not reveal secret values unless --reveal is passed.

    """

    public static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard let subcommand = options.arguments.first else {
            context.writeStdout(helpText)
            return 0
        }

        let args = Array(options.arguments.dropFirst())
        switch subcommand {
        case "help", "--help", "-h":
            context.writeStdout(helpText)
            return 0
        case "put":
            return await runPut(context: &context, arguments: args)
        case "ref":
            return await runRef(context: &context, arguments: args)
        case "get":
            return await runGet(context: &context, arguments: args)
        case "delete", "rm":
            return await runDelete(context: &context, arguments: args)
        case "run":
            return await runWithSecrets(context: &context, arguments: args)
        default:
            context.writeStderr("secrets: unknown subcommand '\(subcommand)'\n")
            context.writeStderr("secrets: run 'secrets --help' for usage\n")
            return 2
        }
    }
}

private extension SecretsCommand {
    struct PutOptions: ParsableArguments {
        @Option(name: [.short, .long], help: "Service name")
        var service: String

        @Option(name: [.customShort("a"), .long], help: "Account name")
        var account: String

        @Option(name: [.customLong("keychain")], help: "Optional keychain routing metadata")
        var keychain: String?

        @Option(name: [.customShort("l"), .long], help: "Optional label")
        var label: String?

        @Option(name: [.customShort("w"), .long], help: "Secret value (discouraged; appears in history)")
        var value: String?

        @Flag(name: [.customLong("stdin")], help: "Read secret value from stdin")
        var stdin = false

        @Flag(name: [.customLong("update")], help: "Update existing secret if present")
        var update = false

        @Flag(name: [.customLong("json")], help: "Emit JSON output")
        var json = false
    }

    struct RefOptions: ParsableArguments {
        @Option(name: [.short, .long], help: "Service name")
        var service: String

        @Option(name: [.customShort("a"), .long], help: "Account name")
        var account: String

        @Option(name: [.customLong("keychain")], help: "Optional keychain routing metadata")
        var keychain: String?

        @Flag(name: [.customLong("json")], help: "Emit JSON output")
        var json = false
    }

    struct GetOptions: ParsableArguments {
        @Argument(help: "Optional secret reference (secretref:v1:...)")
        var reference: String?

        @Option(name: [.short, .long], help: "Service name")
        var service: String?

        @Option(name: [.customShort("a"), .long], help: "Account name")
        var account: String?

        @Option(name: [.customLong("keychain")], help: "Optional keychain routing metadata")
        var keychain: String?

        @Flag(name: [.customShort("w"), .customLong("reveal")], help: "Reveal and print secret value")
        var reveal = false

        @Flag(name: [.customLong("json")], help: "Emit JSON output")
        var json = false
    }

    struct DeleteOptions: ParsableArguments {
        @Argument(help: "Optional secret reference (secretref:v1:...)")
        var reference: String?

        @Option(name: [.short, .long], help: "Service name")
        var service: String?

        @Option(name: [.customShort("a"), .long], help: "Account name")
        var account: String?

        @Option(name: [.customLong("keychain")], help: "Optional keychain routing metadata")
        var keychain: String?

        @Flag(name: [.short, .long], help: "Succeed when secret is missing")
        var force = false
    }

    struct RunInvocation: Sendable {
        struct Binding: Sendable {
            var name: String
            var reference: String
        }

        var bindings: [Binding]
        var command: [String]
    }

    static func runPut(context: inout CommandContext, arguments: [String]) async -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Store or update a secret and emit a secret reference
                
                USAGE: secrets put --service <service> --account <account> [--stdin | --value <value>] [--update] [--json]
                
                """
            )
            return 0
        }

        guard let options: PutOptions = parse(PutOptions.self, arguments: arguments, context: &context) else {
            return 2
        }

        let locator = SecretLocator(
            service: options.service,
            account: options.account,
            keychain: options.keychain
        )

        let value: Data
        do {
            value = try readPutValue(options: options, context: &context)
        } catch {
            return emitError(context: &context, error: error)
        }

        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        do {
            try await runtime.putGenericPassword(
                locator: locator,
                value: value,
                label: options.label,
                update: options.update
            )
        } catch {
            return emitError(context: &context, error: error)
        }

        let reference = SecretReference(locator: locator).stringValue
        if options.json {
            let payload = PutPayload(
                reference: reference,
                service: locator.service,
                account: locator.account,
                keychain: locator.keychain,
                updated: options.update
            )
            return writeJSON(payload, context: &context)
        }

        context.writeStdout(reference + "\n")
        return 0
    }

    static func runRef(context: inout CommandContext, arguments: [String]) async -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Emit a secret reference for an existing secret
                
                USAGE: secrets ref --service <service> --account <account> [--json]
                
                """
            )
            return 0
        }

        guard let options: RefOptions = parse(RefOptions.self, arguments: arguments, context: &context) else {
            return 2
        }

        let locator = SecretLocator(
            service: options.service,
            account: options.account,
            keychain: options.keychain
        )

        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        do {
            _ = try await runtime.getGenericPassword(locator: locator, revealValue: false)
        } catch {
            return emitError(context: &context, error: error)
        }

        let reference = SecretReference(locator: locator).stringValue
        if options.json {
            let payload = ReferencePayload(
                reference: reference,
                service: locator.service,
                account: locator.account,
                keychain: locator.keychain
            )
            return writeJSON(payload, context: &context)
        }

        context.writeStdout(reference + "\n")
        return 0
    }

    static func runGet(context: inout CommandContext, arguments: [String]) async -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Read secret metadata, or reveal value with --reveal
                
                USAGE: secrets get [<secretref>] [--service <service> --account <account>] [--reveal] [--json]
                
                """
            )
            return 0
        }

        guard let options: GetOptions = parse(GetOptions.self, arguments: arguments, context: &context) else {
            return 2
        }

        if options.reveal, options.json {
            return emitError(
                context: &context,
                error: SecretsError.invalidInput("cannot combine --reveal with --json")
            )
        }

        let locator: SecretLocator
        do {
            locator = try resolveLocator(
                reference: options.reference,
                service: options.service,
                account: options.account,
                keychain: options.keychain
            )
        } catch {
            return emitError(context: &context, error: error)
        }

        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        let fetched: SecretFetchResult
        do {
            fetched = try await runtime.getGenericPassword(
                locator: locator,
                revealValue: options.reveal
            )
        } catch {
            return emitError(context: &context, error: error)
        }

        if options.reveal {
            context.stdout.append(fetched.value ?? Data())
            return 0
        }

        let reference = SecretReference(locator: fetched.metadata.locator).stringValue
        if options.json {
            let payload = GetPayload(
                reference: reference,
                service: fetched.metadata.locator.service,
                account: fetched.metadata.locator.account,
                keychain: fetched.metadata.locator.keychain,
                label: fetched.metadata.label
            )
            return writeJSON(payload, context: &context)
        }

        context.writeStdout("service=\(fetched.metadata.locator.service)\n")
        context.writeStdout("account=\(fetched.metadata.locator.account)\n")
        if let label = fetched.metadata.label {
            context.writeStdout("label=\(label)\n")
        }
        context.writeStdout("reference=\(reference)\n")
        return 0
    }

    static func runDelete(context: inout CommandContext, arguments: [String]) async -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Delete a secret by locator or reference
                
                USAGE: secrets delete [<secretref>] [--service <service> --account <account>] [--force]
                
                """
            )
            return 0
        }

        guard let options: DeleteOptions = parse(DeleteOptions.self, arguments: arguments, context: &context) else {
            return 2
        }

        let locator: SecretLocator
        do {
            locator = try resolveLocator(
                reference: options.reference,
                service: options.service,
                account: options.account,
                keychain: options.keychain
            )
        } catch {
            return emitError(context: &context, error: error)
        }

        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        do {
            let removed = try await runtime.deleteGenericPassword(locator: locator)
            if !removed, !options.force {
                return emitError(context: &context, error: SecretsError.notFound(locator))
            }
            return 0
        } catch {
            return emitError(context: &context, error: error)
        }
    }

    static func runWithSecrets(context: inout CommandContext, arguments: [String]) async -> Int32 {
        if arguments == ["--help"] || arguments == ["-h"] {
            context.writeStdout(
                """
                OVERVIEW: Resolve references into env vars for one command
                
                USAGE: secrets run --env NAME=<secretref> [--env NAME=<secretref> ...] -- <command> [args...]
                
                """
            )
            return 0
        }

        let invocation: RunInvocation
        do {
            invocation = try parseRunInvocation(arguments)
        } catch {
            return emitError(context: &context, error: error)
        }

        var ephemeralEnvironment = context.environment
        let runtime = await SecretsRuntimeRegistry.shared.currentRuntime()
        for binding in invocation.bindings {
            let locator: SecretLocator
            guard let reference = SecretReference(string: binding.reference) else {
                return emitError(
                    context: &context,
                    error: SecretsError.invalidReference(binding.reference)
                )
            }
            locator = reference.locator

            let fetched: SecretFetchResult
            do {
                fetched = try await runtime.getGenericPassword(
                    locator: locator,
                    revealValue: true
                )
            } catch {
                return emitError(context: &context, error: error)
            }

            guard let data = fetched.value else {
                return emitError(
                    context: &context,
                    error: SecretsError.runtimeFailure(
                        "secret value missing for service '\(locator.service)' and account '\(locator.account)'"
                    )
                )
            }

            guard let value = String(data: data, encoding: .utf8) else {
                return emitError(
                    context: &context,
                    error: SecretsError.runtimeFailure(
                        "secret for \(binding.name) is not UTF-8 and cannot be injected as an environment variable"
                    )
                )
            }

            ephemeralEnvironment[binding.name] = value
        }

        var isolated = context
        isolated.environment = ephemeralEnvironment

        let outcome = await isolated.runSubcommandIsolated(invocation.command, stdin: context.stdin)
        context.stdout.append(outcome.result.stdout)
        context.stderr.append(outcome.result.stderr)
        return outcome.result.exitCode
    }

    static func parse<T: ParsableArguments>(
        _ type: T.Type,
        arguments: [String],
        context: inout CommandContext
    ) -> T? {
        do {
            return try type.parse(arguments)
        } catch {
            let message = type.fullMessage(for: error)
            if !message.isEmpty {
                let output = message.hasSuffix("\n") ? message : message + "\n"
                let exitCode = type.exitCode(for: error).rawValue
                if exitCode == 0 {
                    context.writeStdout(output)
                } else {
                    context.writeStderr(output)
                }
            }
            return nil
        }
    }

    static func readPutValue(
        options: PutOptions,
        context: inout CommandContext
    ) throws -> Data {
        if options.stdin, options.value != nil {
            throw SecretsError.invalidInput("choose either --stdin or --value, not both")
        }

        if let value = options.value {
            context.writeStderr("secrets: warning: --value exposes secrets to command history; prefer --stdin\n")
            return Data(value.utf8)
        }

        if options.stdin || !context.stdin.isEmpty {
            return context.stdin
        }

        throw SecretsError.invalidInput("missing secret value (pass --stdin or --value)")
    }

    static func resolveLocator(
        reference: String?,
        service: String?,
        account: String?,
        keychain: String?
    ) throws -> SecretLocator {
        if let reference {
            if service != nil || account != nil || keychain != nil {
                throw SecretsError.invalidInput(
                    "reference and explicit --service/--account/--keychain cannot be combined"
                )
            }

            guard let parsed = SecretReference(string: reference)?.locator else {
                throw SecretsError.invalidReference(reference)
            }
            return parsed
        }

        guard let service, !service.isEmpty else {
            throw SecretsError.invalidInput("missing --service")
        }
        guard let account, !account.isEmpty else {
            throw SecretsError.invalidInput("missing --account")
        }
        return SecretLocator(service: service, account: account, keychain: keychain)
    }

    static func parseRunInvocation(_ arguments: [String]) throws -> RunInvocation {
        var bindings: [RunInvocation.Binding] = []
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                break
            }

            if argument == "--env" {
                guard index + 1 < arguments.count else {
                    throw SecretsError.invalidInput("missing NAME=<secretref> after --env")
                }
                bindings.append(try parseRunBinding(arguments[index + 1]))
                index += 2
                continue
            }

            if argument.hasPrefix("--env=") {
                let value = String(argument.dropFirst("--env=".count))
                bindings.append(try parseRunBinding(value))
                index += 1
                continue
            }

            throw SecretsError.invalidInput("unexpected argument '\(argument)' (expected --env or --)")
        }

        guard index < arguments.count, arguments[index] == "--" else {
            throw SecretsError.invalidInput("missing '--' before command")
        }

        let command = Array(arguments[(index + 1)...])
        guard !command.isEmpty else {
            throw SecretsError.invalidInput("missing command after '--'")
        }

        guard !bindings.isEmpty else {
            throw SecretsError.invalidInput("at least one --env binding is required")
        }

        return RunInvocation(bindings: bindings, command: command)
    }

    static func parseRunBinding(_ binding: String) throws -> RunInvocation.Binding {
        guard let equals = binding.firstIndex(of: "="), equals > binding.startIndex else {
            throw SecretsError.invalidInput("invalid --env binding '\(binding)' (expected NAME=<secretref>)")
        }

        let name = String(binding[..<equals])
        let valueStart = binding.index(after: equals)
        let reference = String(binding[valueStart...])
        guard !reference.isEmpty else {
            throw SecretsError.invalidInput("invalid --env binding '\(binding)' (reference is empty)")
        }
        guard isValidEnvironmentVariableName(name) else {
            throw SecretsError.invalidInput("invalid environment variable name '\(name)'")
        }

        return RunInvocation.Binding(name: name, reference: reference)
    }

    static func isValidEnvironmentVariableName(_ name: String) -> Bool {
        guard let first = name.first else {
            return false
        }
        guard first == "_" || first.isLetter else {
            return false
        }
        return name.dropFirst().allSatisfy { character in
            character == "_" || character.isLetter || character.isNumber
        }
    }

    static func emitError(context: inout CommandContext, error: Error) -> Int32 {
        let message: String
        let exitCode: Int32
        if let error = error as? SecretsError {
            message = "secrets: \(error.description)\n"
            switch error {
            case .invalidInput, .invalidReference:
                exitCode = 2
            case .notFound, .duplicateItem, .unsupported, .runtimeFailure:
                exitCode = 1
            }
        } else {
            message = "secrets: \(error)\n"
            exitCode = 1
        }

        context.writeStderr(message)
        return exitCode
    }

    static func writeJSON<T: Encodable>(_ value: T, context: inout CommandContext) -> Int32 {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            context.stdout.append(data)
            context.writeStdout("\n")
            return 0
        } catch {
            return emitError(
                context: &context,
                error: SecretsError.runtimeFailure("failed to encode JSON output")
            )
        }
    }

    struct PutPayload: Encodable {
        var reference: String
        var service: String
        var account: String
        var keychain: String?
        var updated: Bool
    }

    struct ReferencePayload: Encodable {
        var reference: String
        var service: String
        var account: String
        var keychain: String?
    }

    struct GetPayload: Encodable {
        var reference: String
        var service: String
        var account: String
        var keychain: String?
        var label: String?
    }
}
