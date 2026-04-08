import Foundation

package struct ExecutionFailure: Sendable {
    package let exitCode: Int32
    package let message: String
}

package actor ExecutionControl {
    package nonisolated let limits: ExecutionLimits
    private let cancellationCheck: (@Sendable () -> Bool)?
    private let startedAt: TimeInterval

    private var commandCount = 0
    private var functionDepth = 0
    private var commandSubstitutionDepth = 0
    private var permissionPauseDepth = 0
    private var permissionPauseStartedAt: TimeInterval?
    private var pausedDuration: TimeInterval = 0
    private var timeoutFailure: ExecutionFailure?

    package init(
        limits: ExecutionLimits,
        cancellationCheck: (@Sendable () -> Bool)? = nil
    ) {
        self.limits = limits
        self.cancellationCheck = cancellationCheck
        self.startedAt = Self.monotonicNow()
    }

    package func checkpoint() -> ExecutionFailure? {
        if let timeoutFailure {
            return timeoutFailure
        }

        if let maxWallClockDuration = limits.maxWallClockDuration,
           effectiveElapsedTime() >= maxWallClockDuration {
            let failure = ExecutionFailure(exitCode: 124, message: "execution timed out")
            timeoutFailure = failure
            return failure
        }

        if Task.isCancelled || cancellationCheck?() == true {
            return ExecutionFailure(exitCode: 130, message: "execution cancelled")
        }
        return nil
    }

    package func recordCommandExecution(commandName: String) -> ExecutionFailure? {
        if let failure = checkpoint() {
            return failure
        }

        commandCount += 1
        guard commandCount <= limits.maxCommandCount else {
            return ExecutionFailure(
                exitCode: 2,
                message: "execution limit exceeded: maximum command count (\(limits.maxCommandCount))"
            )
        }
        return nil
    }

    package func recordLoopIteration(loopName: String, iteration: Int) -> ExecutionFailure? {
        if let failure = checkpoint() {
            return failure
        }

        guard iteration <= limits.maxLoopIterations else {
            return ExecutionFailure(
                exitCode: 2,
                message: "\(loopName): exceeded max iterations"
            )
        }
        return nil
    }

    package func pushFunction() -> ExecutionFailure? {
        if let failure = checkpoint() {
            return failure
        }

        functionDepth += 1
        guard functionDepth <= limits.maxFunctionDepth else {
            functionDepth -= 1
            return ExecutionFailure(
                exitCode: 2,
                message: "execution limit exceeded: maximum function depth (\(limits.maxFunctionDepth))"
            )
        }
        return nil
    }

    package func popFunction() {
        functionDepth = max(0, functionDepth - 1)
    }

    package func pushCommandSubstitution() -> ExecutionFailure? {
        if let failure = checkpoint() {
            return failure
        }

        commandSubstitutionDepth += 1
        guard commandSubstitutionDepth <= limits.maxCommandSubstitutionDepth else {
            commandSubstitutionDepth -= 1
            return ExecutionFailure(
                exitCode: 2,
                message: "execution limit exceeded: maximum command substitution depth (\(limits.maxCommandSubstitutionDepth))"
            )
        }
        return nil
    }

    package func popCommandSubstitution() {
        commandSubstitutionDepth = max(0, commandSubstitutionDepth - 1)
    }

    package func currentEffectiveElapsedTime() -> TimeInterval {
        effectiveElapsedTime()
    }

    package func beginPermissionPause() {
        if permissionPauseDepth == 0 {
            permissionPauseStartedAt = Self.monotonicNow()
        }
        permissionPauseDepth += 1
    }

    package func endPermissionPause() {
        guard permissionPauseDepth > 0 else {
            return
        }

        permissionPauseDepth -= 1
        guard permissionPauseDepth == 0,
              let permissionPauseStartedAt
        else {
            return
        }

        pausedDuration += max(0, Self.monotonicNow() - permissionPauseStartedAt)
        self.permissionPauseStartedAt = nil
    }

    package func markTimedOut(message: String = "execution timed out") {
        timeoutFailure = ExecutionFailure(exitCode: 124, message: message)
    }

    private func effectiveElapsedTime() -> TimeInterval {
        let now = Self.monotonicNow()
        var effectivePausedDuration = pausedDuration
        if let permissionPauseStartedAt {
            effectivePausedDuration += max(0, now - permissionPauseStartedAt)
        }

        return max(0, now - startedAt - effectivePausedDuration)
    }

    nonisolated private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}
