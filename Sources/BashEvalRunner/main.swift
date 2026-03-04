import ArgumentParser
import Bash
import Foundation
import Yams

enum EngineKind: String, CaseIterable, ExpressibleByArgument {
    case bashswift = "bashswift"
    case systemBash = "system-bash"
}

struct EvalProfile: Decodable {
    struct RunLimits: Codable {
        let maxSteps: Int
        let maxWallTimeSeconds: Int
        let maxCommandOutputBytes: Int

        enum CodingKeys: String, CodingKey {
            case maxSteps = "max_steps"
            case maxWallTimeSeconds = "max_wall_time_seconds"
            case maxCommandOutputBytes = "max_command_output_bytes"
        }
    }

    let name: String
    let version: String
    let taskBank: String
    let runLimits: RunLimits

    enum CodingKeys: String, CodingKey {
        case name
        case version
        case taskBank = "task_bank"
        case runLimits = "run_limits"
    }
}

struct EvalTaskBank: Decodable {
    let version: String
    let tasks: [EvalTask]
}

struct EvalTask: Decodable {
    let id: String
    let tier: String
    let prompt: String
    let setup: [String]
    let validate: [String]
    let tags: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case tier
        case prompt
        case setup
        case validate
        case tags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tier = try container.decode(String.self, forKey: .tier)
        prompt = try container.decode(String.self, forKey: .prompt)
        setup = try container.decodeIfPresent([String].self, forKey: .setup) ?? []
        validate = try container.decodeIfPresent([String].self, forKey: .validate) ?? []
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    }
}

struct CommandRecord: Encodable {
    let command: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let durationMs: Int

    enum CodingKeys: String, CodingKey {
        case command
        case exitCode = "exit_code"
        case stdout
        case stderr
        case stdoutTruncated = "stdout_truncated"
        case stderrTruncated = "stderr_truncated"
        case durationMs = "duration_ms"
    }
}

enum TaskStatus: String, Encodable {
    case passed
    case failed
    case skipped
}

struct TaskReport: Encodable {
    let id: String
    let tier: String
    let status: TaskStatus
    let passed: Bool
    let failureBucket: String?
    let failureReason: String?
    let workspace: String
    let prompt: String
    let commandsSource: String
    let setup: [CommandRecord]
    let agent: [CommandRecord]
    let validate: [CommandRecord]
    let durationMs: Int

    enum CodingKeys: String, CodingKey {
        case id
        case tier
        case status
        case passed
        case failureBucket = "failure_bucket"
        case failureReason = "failure_reason"
        case workspace
        case prompt
        case commandsSource = "commands_source"
        case setup
        case agent
        case validate
        case durationMs = "duration_ms"
    }
}

struct ReportSummary: Encodable {
    let total: Int
    let passed: Int
    let failed: Int
    let skipped: Int
    let coreTotal: Int
    let corePassed: Int
    let gapProbeTotal: Int
    let gapProbePassed: Int
    let corePassRate: Double
    let gapProbePassRate: Double
    let unsupportedCommandRate: Double
    let parserOrLanguageGapRate: Double
    let semanticMismatchRate: Double
    let medianStepsToPass: Double

    enum CodingKeys: String, CodingKey {
        case total
        case passed
        case failed
        case skipped
        case coreTotal = "core_total"
        case corePassed = "core_passed"
        case gapProbeTotal = "gap_probe_total"
        case gapProbePassed = "gap_probe_passed"
        case corePassRate = "core_pass_rate"
        case gapProbePassRate = "gap_probe_pass_rate"
        case unsupportedCommandRate = "unsupported_command_rate"
        case parserOrLanguageGapRate = "parser_or_language_gap_rate"
        case semanticMismatchRate = "semantic_mismatch_rate"
        case medianStepsToPass = "median_steps_to_pass"
    }
}

struct EvalReport: Encodable {
    let runID: String
    let profileName: String
    let profileVersion: String
    let profilePath: String
    let taskBankPath: String
    let engine: String
    let commandsSource: String
    let startedAt: Date
    let finishedAt: Date
    let runLimits: EvalProfile.RunLimits
    let selectedTaskIDs: [String]
    let summary: ReportSummary
    let tasks: [TaskReport]

    enum CodingKeys: String, CodingKey {
        case runID = "run_id"
        case profileName = "profile_name"
        case profileVersion = "profile_version"
        case profilePath = "profile_path"
        case taskBankPath = "task_bank_path"
        case engine
        case commandsSource = "commands_source"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case runLimits = "run_limits"
        case selectedTaskIDs = "selected_task_ids"
        case summary
        case tasks
    }
}

protocol CandidateEngine {
    func run(command: String) async throws -> CommandRecord
}

struct SystemBashEngine: CandidateEngine {
    let workspaceURL: URL
    let maxOutputBytes: Int

    func run(command: String) async throws -> CommandRecord {
        try await ProcessCommandRunner.run(
            command: command,
            workspaceURL: workspaceURL,
            maxOutputBytes: maxOutputBytes,
            extraEnvironment: nil
        )
    }
}

final class BashSwiftEngine: CandidateEngine {
    private static let pwdHostRootEnvKey = "BASHSWIFT_PWD_HOST_ROOT"
    private let session: BashSession
    private let maxOutputBytes: Int

    init(workspaceURL: URL, maxOutputBytes: Int) async throws {
        let hostRootProbe = try await ProcessCommandRunner.run(
            command: "pwd",
            workspaceURL: workspaceURL,
            maxOutputBytes: 4_096,
            extraEnvironment: nil
        )
        let hostRoot = hostRootProbe.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveHostRoot = hostRoot.isEmpty
            ? workspaceURL.standardizedFileURL.path
            : hostRoot

        session = try await BashSession(
            rootDirectory: workspaceURL,
            options: SessionOptions(
                layout: .rootOnly,
                initialEnvironment: [Self.pwdHostRootEnvKey: effectiveHostRoot]
            )
        )
        self.maxOutputBytes = maxOutputBytes
    }

    func run(command: String) async throws -> CommandRecord {
        let started = Date()
        let result = await session.run(command)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        let stdout = ProcessCommandRunner.truncate(result.stdout, maxBytes: maxOutputBytes)
        let stderr = ProcessCommandRunner.truncate(result.stderr, maxBytes: maxOutputBytes)

        return CommandRecord(
            command: command,
            exitCode: result.exitCode,
            stdout: stdout.text,
            stderr: stderr.text,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated,
            durationMs: durationMs
        )
    }
}

enum ProcessCommandRunner {
    struct TruncatedText {
        let text: String
        let truncated: Bool
    }

    static func run(
        command: String,
        workspaceURL: URL,
        maxOutputBytes: Int,
        extraEnvironment: [String: String]?
    ) async throws -> CommandRecord {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workspaceURL

        if let extraEnvironment {
            var merged = ProcessInfo.processInfo.environment
            for (key, value) in extraEnvironment {
                merged[key] = value
            }
            process.environment = merged
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        let started = Date()
        do {
            try process.run()
        } catch {
            let durationMs = Int(Date().timeIntervalSince(started) * 1000)
            return CommandRecord(
                command: command,
                exitCode: 127,
                stdout: "",
                stderr: "failed to launch /bin/bash: \(error)",
                stdoutTruncated: false,
                stderrTruncated: false,
                durationMs: durationMs
            )
        }

        process.waitUntilExit()

        let stdoutData = await stdoutTask.value
        let stderrData = await stderrTask.value
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)

        let stdout = truncate(stdoutData, maxBytes: maxOutputBytes)
        let stderr = truncate(stderrData, maxBytes: maxOutputBytes)

        return CommandRecord(
            command: command,
            exitCode: process.terminationStatus,
            stdout: stdout.text,
            stderr: stderr.text,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated,
            durationMs: durationMs
        )
    }

    static func truncate(_ data: Data, maxBytes: Int) -> TruncatedText {
        guard data.count > maxBytes else {
            return TruncatedText(
                text: String(decoding: data, as: UTF8.self),
                truncated: false
            )
        }

        let prefix = data.prefix(maxBytes)
        let marker = "\n[truncated]\n"
        return TruncatedText(
            text: String(decoding: prefix, as: UTF8.self) + marker,
            truncated: true
        )
    }
}

struct CommandsLookup {
    let taskPlans: [String: [String]]
    let defaultPlan: [String]?

    func commands(for taskID: String) -> [String]? {
        if let specific = taskPlans[taskID] {
            return specific
        }
        return defaultPlan
    }
}

private struct CommandsEnvelope: Decodable {
    let tasks: [String: [String]]?
    let defaultPlan: [String]?

    enum CodingKeys: String, CodingKey {
        case tasks
        case defaultPlan = "default"
    }
}

@main
struct BashEvalRunner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "BashEvalRunner",
        abstract: "Run Bash.swift NL task eval profiles and emit a JSON report."
    )

    @Option(name: [.customLong("profile")], help: "Path to profile YAML.")
    var profilePath: String = "docs/evals/general/profile.yaml"

    @Option(name: [.customLong("tasks")], help: "Optional override path to task bank YAML.")
    var tasksPath: String?

    @Option(name: [.customLong("engine")], help: "Candidate engine: bashswift or system-bash.")
    var engine: EngineKind = .bashswift

    @Option(name: [.customLong("task")], parsing: .upToNextOption, help: "Task ID to run (repeat flag to include more).")
    var taskIDs: [String] = []

    @Option(name: [.customLong("commands-file")], help: "Path to JSON command plans: either {\"task_id\":[...]} or {\"tasks\":{...},\"default\":[...]}.")
    var commandsFilePath: String?

    @Option(name: [.customLong("agent-command")], help: "Shell command that prints candidate commands, one per line. Receives EVAL_TASK_* env vars.")
    var agentCommand: String?

    @Option(name: [.customLong("report")], help: "Path to write JSON report.")
    var reportPath: String?

    @Option(name: [.customLong("max-steps")], help: "Override max steps per task.")
    var maxStepsOverride: Int?

    @Flag(name: [.customLong("keep-workspaces")], help: "Keep per-task temp workspace directories.")
    var keepWorkspaces = false

    @Flag(name: [.customLong("verbose")], help: "Print per-task execution progress.")
    var verbose = false

    mutating func run() async throws {
        if commandsFilePath == nil && agentCommand == nil {
            throw ValidationError("Specify at least one of --commands-file or --agent-command.")
        }

        let cwdURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let profileURL = resolve(path: profilePath, relativeTo: cwdURL)
        let profileDirectoryURL = profileURL.deletingLastPathComponent()

        let profile = try loadYAML(EvalProfile.self, from: profileURL)

        let taskBankURL: URL
        if let tasksPath {
            taskBankURL = resolve(path: tasksPath, relativeTo: cwdURL)
        } else {
            let fromProfileDirectory = resolve(path: profile.taskBank, relativeTo: profileDirectoryURL)
            if FileManager.default.fileExists(atPath: fromProfileDirectory.path) {
                taskBankURL = fromProfileDirectory
            } else {
                taskBankURL = resolve(path: profile.taskBank, relativeTo: cwdURL)
            }
        }

        let taskBank = try loadYAML(EvalTaskBank.self, from: taskBankURL)

        let selectedTasks = try selectTasks(from: taskBank.tasks, requestedIDs: taskIDs)
        let commandsLookup = try loadCommandsLookupIfNeeded(commandsFilePath: commandsFilePath, cwdURL: cwdURL)

        let maxSteps = maxStepsOverride ?? profile.runLimits.maxSteps
        guard maxSteps > 0 else {
            throw ValidationError("max steps must be > 0")
        }

        let runID = makeRunID()
        let runRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bash-eval-\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: runRootURL, withIntermediateDirectories: true)

        let startedAt = Date()
        var taskReports: [TaskReport] = []

        for task in selectedTasks {
            let report = try await runTask(
                task: task,
                engine: engine,
                commandsLookup: commandsLookup,
                agentCommand: agentCommand,
                maxSteps: maxSteps,
                maxOutputBytes: profile.runLimits.maxCommandOutputBytes,
                runRootURL: runRootURL
            )
            taskReports.append(report)

            if verbose {
                FileHandle.standardError.write(
                    Data("[\(task.id)] \(report.status.rawValue)\n".utf8)
                )
            }
        }

        if !keepWorkspaces {
            try? FileManager.default.removeItem(at: runRootURL)
        }

        let finishedAt = Date()
        let summary = summarize(taskReports)

        let report = EvalReport(
            runID: runID,
            profileName: profile.name,
            profileVersion: profile.version,
            profilePath: profileURL.path,
            taskBankPath: taskBankURL.path,
            engine: engine.rawValue,
            commandsSource: commandsSourceName(commandsLookup: commandsLookup, agentCommand: agentCommand),
            startedAt: startedAt,
            finishedAt: finishedAt,
            runLimits: EvalProfile.RunLimits(
                maxSteps: maxSteps,
                maxWallTimeSeconds: profile.runLimits.maxWallTimeSeconds,
                maxCommandOutputBytes: profile.runLimits.maxCommandOutputBytes
            ),
            selectedTaskIDs: selectedTasks.map(\ .id),
            summary: summary,
            tasks: taskReports
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(report)

        if let reportPath {
            let outputURL = resolve(path: reportPath, relativeTo: cwdURL)
            try data.write(to: outputURL)
            print("wrote report: \(outputURL.path)")
        }

        if reportPath == nil || verbose {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        print(
            "summary: total=\(summary.total) passed=\(summary.passed) failed=\(summary.failed) skipped=\(summary.skipped) core_pass_rate=\(formatRate(summary.corePassRate))"
        )
    }

    private func runTask(
        task: EvalTask,
        engine: EngineKind,
        commandsLookup: CommandsLookup?,
        agentCommand: String?,
        maxSteps: Int,
        maxOutputBytes: Int,
        runRootURL: URL
    ) async throws -> TaskReport {
        let started = Date()
        let workspaceURL = runRootURL.appendingPathComponent(safeWorkspaceName(for: task.id), isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)

        var setupRecords: [CommandRecord] = []
        var agentRecords: [CommandRecord] = []
        var validateRecords: [CommandRecord] = []

        for command in task.setup {
            let record = try await ProcessCommandRunner.run(
                command: command,
                workspaceURL: workspaceURL,
                maxOutputBytes: maxOutputBytes,
                extraEnvironment: nil
            )
            setupRecords.append(record)
            if record.exitCode != 0 {
                return TaskReport(
                    id: task.id,
                    tier: task.tier,
                    status: .failed,
                    passed: false,
                    failureBucket: "agent-error",
                    failureReason: "setup command failed: \(command)",
                    workspace: workspaceURL.path,
                    prompt: task.prompt,
                    commandsSource: commandsSourceName(commandsLookup: commandsLookup, agentCommand: agentCommand),
                    setup: setupRecords,
                    agent: agentRecords,
                    validate: validateRecords,
                    durationMs: Int(Date().timeIntervalSince(started) * 1000)
                )
            }
        }

        let commandSelection = try await resolveAgentCommands(
            task: task,
            workspaceURL: workspaceURL,
            commandsLookup: commandsLookup,
            agentCommand: agentCommand,
            maxSteps: maxSteps,
            maxOutputBytes: maxOutputBytes
        )

        if commandSelection.commands.isEmpty {
            return TaskReport(
                id: task.id,
                tier: task.tier,
                status: .skipped,
                passed: false,
                failureBucket: nil,
                failureReason: commandSelection.reason,
                workspace: workspaceURL.path,
                prompt: task.prompt,
                commandsSource: commandSelection.source,
                setup: setupRecords,
                agent: commandSelection.plannerRecord.map { [$0] } ?? [],
                validate: validateRecords,
                durationMs: Int(Date().timeIntervalSince(started) * 1000)
            )
        }

        let candidateEngine: CandidateEngine
        switch engine {
        case .systemBash:
            candidateEngine = SystemBashEngine(workspaceURL: workspaceURL, maxOutputBytes: maxOutputBytes)
        case .bashswift:
            candidateEngine = try await BashSwiftEngine(workspaceURL: workspaceURL, maxOutputBytes: maxOutputBytes)
        }

        for command in commandSelection.commands {
            let record = try await candidateEngine.run(command: command)
            agentRecords.append(record)
        }

        for command in task.validate {
            let record = try await ProcessCommandRunner.run(
                command: command,
                workspaceURL: workspaceURL,
                maxOutputBytes: maxOutputBytes,
                extraEnvironment: nil
            )
            validateRecords.append(record)
        }

        let passed = validateRecords.allSatisfy { $0.exitCode == 0 }
        let failureBucket = passed ? nil : classifyFailure(agentRecords: agentRecords, validateRecords: validateRecords)

        return TaskReport(
            id: task.id,
            tier: task.tier,
            status: passed ? .passed : .failed,
            passed: passed,
            failureBucket: failureBucket,
            failureReason: passed ? nil : "one or more validators failed",
            workspace: workspaceURL.path,
            prompt: task.prompt,
            commandsSource: commandSelection.source,
            setup: setupRecords,
            agent: agentRecords,
            validate: validateRecords,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    private func resolveAgentCommands(
        task: EvalTask,
        workspaceURL: URL,
        commandsLookup: CommandsLookup?,
        agentCommand: String?,
        maxSteps: Int,
        maxOutputBytes: Int
    ) async throws -> (commands: [String], source: String, reason: String?, plannerRecord: CommandRecord?) {
        if let commandsLookup {
            if let plan = commandsLookup.commands(for: task.id) {
                return (
                    commands: Array(plan.prefix(maxSteps)),
                    source: "commands-file",
                    reason: nil,
                    plannerRecord: nil
                )
            }

            return (
                commands: [],
                source: "commands-file",
                reason: "no command plan found for task",
                plannerRecord: nil
            )
        }

        guard let agentCommand else {
            return (
                commands: [],
                source: "none",
                reason: "no command source configured",
                plannerRecord: nil
            )
        }

        let env: [String: String] = [
            "EVAL_TASK_ID": task.id,
            "EVAL_TASK_TIER": task.tier,
            "EVAL_TASK_PROMPT": task.prompt,
            "EVAL_MAX_STEPS": String(maxSteps),
            "EVAL_WORKSPACE": workspaceURL.path,
        ]

        let plannerRecord = try await ProcessCommandRunner.run(
            command: agentCommand,
            workspaceURL: workspaceURL,
            maxOutputBytes: maxOutputBytes,
            extraEnvironment: env
        )

        if plannerRecord.exitCode != 0 {
            return (
                commands: [],
                source: "agent-command",
                reason: "agent command returned non-zero exit: \(plannerRecord.exitCode)",
                plannerRecord: plannerRecord
            )
        }

        let commands = parseCommandLines(from: plannerRecord.stdout)
        return (
            commands: Array(commands.prefix(maxSteps)),
            source: "agent-command",
            reason: commands.isEmpty ? "agent command produced no commands" : nil,
            plannerRecord: plannerRecord
        )
    }

    private func parseCommandLines(from raw: String) -> [String] {
        raw.split(whereSeparator: \ .isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                if line.hasPrefix("```") {
                    return nil
                }

                if line.hasPrefix("#") {
                    return nil
                }

                if line.hasPrefix("$ ") {
                    return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }

                return line
            }
    }

    private func classifyFailure(agentRecords: [CommandRecord], validateRecords: [CommandRecord]) -> String {
        if agentRecords.contains(where: {
            $0.exitCode == 127 || $0.stderr.localizedCaseInsensitiveContains("command not found")
        }) {
            return "missing-command"
        }

        if agentRecords.contains(where: {
            let stderr = $0.stderr.lowercased()
            return stderr.contains("unknown option")
                || stderr.contains("unrecognized option")
                || stderr.contains("invalid option")
                || stderr.contains("unknown flag")
        }) {
            return "unsupported-flag"
        }

        if agentRecords.contains(where: {
            let stderr = $0.stderr.lowercased()
            return $0.exitCode == 2
                && (
                    stderr.contains("parser")
                        || stderr.contains("unexpected token")
                        || stderr.contains("trailing chain operator")
                        || stderr.contains("unterminated")
                        || stderr.contains("missing redirection target")
                        || stderr.contains("expected command")
                )
        }) {
            return "parser-language-gap"
        }

        let usedPipesOrRedirections = agentRecords.contains(where: {
            $0.command.contains("|")
                || $0.command.contains(">")
                || $0.command.contains("<")
                || $0.command.contains("2>&1")
        })

        if usedPipesOrRedirections && validateRecords.contains(where: { $0.exitCode != 0 }) {
            return "pipeline-redirection-mismatch"
        }

        let hadAgentNonZero = agentRecords.contains(where: { $0.exitCode != 0 })
        if hadAgentNonZero {
            return "exit-code-mismatch"
        }

        if validateRecords.contains(where: { $0.exitCode != 0 }) {
            return "filesystem-state-mismatch"
        }

        return "agent-error"
    }

    private func summarize(_ tasks: [TaskReport]) -> ReportSummary {
        let total = tasks.count
        let passed = tasks.filter(\ .passed).count
        let failed = tasks.filter { $0.status == .failed }.count
        let skipped = tasks.filter { $0.status == .skipped }.count

        let core = tasks.filter { $0.tier == "core" }
        let coreTotal = core.count
        let corePassed = core.filter(\ .passed).count

        let probes = tasks.filter { $0.tier == "gap-probe" }
        let gapProbeTotal = probes.count
        let gapProbePassed = probes.filter(\ .passed).count

        let failedTasks = tasks.filter { $0.status == .failed }
        let unsupportedCommand = failedTasks.filter { $0.failureBucket == "missing-command" }.count
        let parserGap = failedTasks.filter { $0.failureBucket == "parser-language-gap" }.count
        let semanticMismatch = failedTasks.filter {
            $0.failureBucket == "filesystem-state-mismatch"
                || $0.failureBucket == "pipeline-redirection-mismatch"
                || $0.failureBucket == "stdout-stderr-mismatch"
                || $0.failureBucket == "exit-code-mismatch"
        }.count

        let passedSteps = tasks
            .filter(\ .passed)
            .map { report in
                report.agent.filter { !$0.command.hasPrefix("#") }.count
            }
            .sorted()

        let medianStepsToPass: Double
        if passedSteps.isEmpty {
            medianStepsToPass = 0
        } else if passedSteps.count % 2 == 1 {
            medianStepsToPass = Double(passedSteps[passedSteps.count / 2])
        } else {
            let upper = passedSteps.count / 2
            let lower = upper - 1
            medianStepsToPass = Double(passedSteps[lower] + passedSteps[upper]) / 2.0
        }

        return ReportSummary(
            total: total,
            passed: passed,
            failed: failed,
            skipped: skipped,
            coreTotal: coreTotal,
            corePassed: corePassed,
            gapProbeTotal: gapProbeTotal,
            gapProbePassed: gapProbePassed,
            corePassRate: rate(numerator: corePassed, denominator: coreTotal),
            gapProbePassRate: rate(numerator: gapProbePassed, denominator: gapProbeTotal),
            unsupportedCommandRate: rate(numerator: unsupportedCommand, denominator: failedTasks.count),
            parserOrLanguageGapRate: rate(numerator: parserGap, denominator: failedTasks.count),
            semanticMismatchRate: rate(numerator: semanticMismatch, denominator: failedTasks.count),
            medianStepsToPass: medianStepsToPass
        )
    }

    private func selectTasks(from tasks: [EvalTask], requestedIDs: [String]) throws -> [EvalTask] {
        guard !requestedIDs.isEmpty else {
            return tasks
        }

        let requested = Set(requestedIDs)
        let known = Set(tasks.map(\ .id))
        let missing = requested.subtracting(known)
        if !missing.isEmpty {
            let sortedMissing = missing.sorted().joined(separator: ", ")
            throw ValidationError("unknown task ids: \(sortedMissing)")
        }

        return tasks.filter { requested.contains($0.id) }
    }

    private func loadCommandsLookupIfNeeded(commandsFilePath: String?, cwdURL: URL) throws -> CommandsLookup? {
        guard let commandsFilePath else {
            return nil
        }

        let commandsURL = resolve(path: commandsFilePath, relativeTo: cwdURL)
        let data = try Data(contentsOf: commandsURL)
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(CommandsEnvelope.self, from: data),
           envelope.tasks != nil || envelope.defaultPlan != nil
        {
            return CommandsLookup(
                taskPlans: envelope.tasks ?? [:],
                defaultPlan: envelope.defaultPlan
            )
        }

        if let direct = try? decoder.decode([String: [String]].self, from: data) {
            return CommandsLookup(taskPlans: direct, defaultPlan: direct["*"])
        }

        throw ValidationError(
            "invalid commands file format: expected {\"task\":[...]} or {\"tasks\":{...},\"default\":[...]}"
        )
    }

    private func loadYAML<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try YAMLDecoder().decode(type, from: text)
    }

    private func resolve(path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return baseURL.appendingPathComponent(path)
    }

    private func safeWorkspaceName(for taskID: String) -> String {
        taskID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+",
            with: "-",
            options: .regularExpression
        )
    }

    private func makeRunID() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
        return "\(timestamp)-\(UUID().uuidString.prefix(8))"
    }

    private func rate(numerator: Int, denominator: Int) -> Double {
        guard denominator > 0 else {
            return 0
        }
        return (Double(numerator) / Double(denominator) * 10_000).rounded() / 10_000
    }

    private func formatRate(_ value: Double) -> String {
        String(format: "%.4f", value)
    }

    private func commandsSourceName(commandsLookup: CommandsLookup?, agentCommand: String?) -> String {
        if commandsLookup != nil {
            return "commands-file"
        }

        if agentCommand != nil {
            return "agent-command"
        }

        return "none"
    }
}
