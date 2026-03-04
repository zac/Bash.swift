import Foundation

enum ShellJobState: Sendable {
    case running
    case done(exitCode: Int32)
}

struct ShellJobSnapshot: Sendable {
    let id: Int
    let pid: Int
    let commandLine: String
    let state: ShellJobState
    let launchedAt: Date
}

struct ShellJobCompletion: Sendable {
    let id: Int
    let pid: Int
    let commandLine: String
    let result: CommandResult
}

struct ShellBackgroundLaunch: Sendable {
    let jobID: Int
    let pid: Int
}

enum ShellJobReference: Sendable {
    case jobID(Int)
    case pid(Int)
}

protocol ShellJobControlling: Sendable {
    func launchBackgroundJob(
        commandLine: String,
        operation: @escaping @Sendable () async -> CommandResult
    ) async -> ShellBackgroundLaunch

    func latestBackgroundPID() async -> Int?
    func listJobs() async -> [ShellJobSnapshot]
    func hasJobs() async -> Bool
    func hasJob(id: Int) async -> Bool
    func hasProcess(pid: Int) async -> Bool
    func jobSnapshot(id: Int) async -> ShellJobSnapshot?
    func processSnapshot(pid: Int) async -> ShellJobSnapshot?
    func foreground(jobID: Int?) async -> ShellJobCompletion?
    func waitForJob(id: Int) async -> ShellJobCompletion?
    func waitForAllJobs() async -> [ShellJobCompletion]
    func terminate(reference: ShellJobReference, signal: Int32) async -> Bool
}

actor ShellJobManager: ShellJobControlling {
    private struct JobRecord {
        let id: Int
        let pid: Int
        let commandLine: String
        let launchedAt: Date
        var state: ShellJobState
        var result: CommandResult?
        var task: Task<CommandResult, Never>?
    }

    private var nextJobID = 1
    private var nextPseudoPID = 2_000
    private var jobsByID: [Int: JobRecord] = [:]
    private var jobIDByPID: [Int: Int] = [:]
    private var jobOrder: [Int] = []
    private var lastBackgroundPID: Int?

    func launchBackgroundJob(
        commandLine: String,
        operation: @escaping @Sendable () async -> CommandResult
    ) async -> ShellBackgroundLaunch {
        let id = nextJobID
        nextJobID += 1

        let pid = nextPseudoPID
        nextPseudoPID += 1

        let task = Task(priority: .background) {
            await operation()
        }

        let launchedAt = Date()
        jobsByID[id] = JobRecord(
            id: id,
            pid: pid,
            commandLine: commandLine,
            launchedAt: launchedAt,
            state: .running,
            result: nil,
            task: task
        )
        jobIDByPID[pid] = id
        jobOrder.append(id)
        lastBackgroundPID = pid

        Task { [task, id] in
            let result = await task.value
            self.markCompleted(id: id, result: result)
        }

        return ShellBackgroundLaunch(jobID: id, pid: pid)
    }

    func latestBackgroundPID() async -> Int? {
        lastBackgroundPID
    }

    func listJobs() async -> [ShellJobSnapshot] {
        jobOrder.compactMap { id in
            guard let record = jobsByID[id] else {
                return nil
            }
            return ShellJobSnapshot(
                id: record.id,
                pid: record.pid,
                commandLine: record.commandLine,
                state: record.state,
                launchedAt: record.launchedAt
            )
        }
    }

    func hasJobs() async -> Bool {
        !jobsByID.isEmpty
    }

    func hasJob(id: Int) async -> Bool {
        jobsByID[id] != nil
    }

    func hasProcess(pid: Int) async -> Bool {
        jobIDByPID[pid] != nil
    }

    func jobSnapshot(id: Int) async -> ShellJobSnapshot? {
        guard let record = jobsByID[id] else {
            return nil
        }
        return snapshot(from: record)
    }

    func processSnapshot(pid: Int) async -> ShellJobSnapshot? {
        guard let jobID = jobIDByPID[pid], let record = jobsByID[jobID] else {
            return nil
        }
        return snapshot(from: record)
    }

    func foreground(jobID: Int?) async -> ShellJobCompletion? {
        guard let resolved = resolveJobID(jobID) else {
            return nil
        }
        return await consumeJob(id: resolved)
    }

    func waitForJob(id: Int) async -> ShellJobCompletion? {
        await consumeJob(id: id)
    }

    func waitForAllJobs() async -> [ShellJobCompletion] {
        let ids = jobOrder
        var completions: [ShellJobCompletion] = []
        completions.reserveCapacity(ids.count)

        for id in ids {
            if let completion = await consumeJob(id: id) {
                completions.append(completion)
            }
        }

        return completions
    }

    func terminate(reference: ShellJobReference, signal: Int32) async -> Bool {
        let resolvedID: Int
        switch reference {
        case let .jobID(id):
            resolvedID = id
        case let .pid(pid):
            guard let mappedID = jobIDByPID[pid] else {
                return false
            }
            resolvedID = mappedID
        }

        guard var record = jobsByID[resolvedID] else {
            return false
        }

        if signal == 0 {
            return true
        }

        if case .done = record.state {
            return true
        }

        let exitCode = Int32(128 + max(0, signal))
        record.state = .done(exitCode: exitCode)
        record.result = CommandResult(stdout: Data(), stderr: Data(), exitCode: exitCode)
        record.task?.cancel()
        record.task = nil
        jobsByID[resolvedID] = record
        return true
    }

    private func resolveJobID(_ requested: Int?) -> Int? {
        if let requested {
            guard jobsByID[requested] != nil else {
                return nil
            }
            return requested
        }
        return jobOrder.last
    }

    private func consumeJob(id: Int) async -> ShellJobCompletion? {
        guard let initial = jobsByID[id] else {
            return nil
        }

        let result: CommandResult
        if let cached = initial.result {
            result = cached
        } else if let task = initial.task {
            result = await task.value
            markCompleted(id: id, result: result)
        } else {
            return nil
        }

        guard let record = jobsByID[id] else {
            return ShellJobCompletion(id: id, pid: initial.pid, commandLine: initial.commandLine, result: result)
        }

        removeJob(id: id)
        return ShellJobCompletion(id: record.id, pid: record.pid, commandLine: record.commandLine, result: result)
    }

    private func markCompleted(id: Int, result: CommandResult) {
        guard var record = jobsByID[id] else {
            return
        }

        if case .done = record.state {
            return
        }

        record.state = .done(exitCode: result.exitCode)
        record.result = result
        record.task = nil
        jobsByID[id] = record
    }

    private func removeJob(id: Int) {
        if let record = jobsByID[id] {
            jobIDByPID.removeValue(forKey: record.pid)
        }
        jobsByID.removeValue(forKey: id)
        jobOrder.removeAll { $0 == id }
    }

    private func snapshot(from record: JobRecord) -> ShellJobSnapshot {
        ShellJobSnapshot(
            id: record.id,
            pid: record.pid,
            commandLine: record.commandLine,
            state: record.state,
            launchedAt: record.launchedAt
        )
    }
}
