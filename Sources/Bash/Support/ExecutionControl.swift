import Foundation

struct ExecutionFailure: Sendable {
    let exitCode: Int32
    let message: String
}

actor ExecutionControl {
    nonisolated let limits: ExecutionLimits
    private let cancellationCheck: (@Sendable () -> Bool)?

    private var commandCount = 0
    private var functionDepth = 0
    private var commandSubstitutionDepth = 0

    init(
        limits: ExecutionLimits,
        cancellationCheck: (@Sendable () -> Bool)? = nil
    ) {
        self.limits = limits
        self.cancellationCheck = cancellationCheck
    }

    func checkpoint() -> ExecutionFailure? {
        if Task.isCancelled || cancellationCheck?() == true {
            return ExecutionFailure(exitCode: 130, message: "execution cancelled")
        }
        return nil
    }

    func recordCommandExecution(commandName: String) -> ExecutionFailure? {
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

    func recordLoopIteration(loopName: String, iteration: Int) -> ExecutionFailure? {
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

    func pushFunction() -> ExecutionFailure? {
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

    func popFunction() {
        functionDepth = max(0, functionDepth - 1)
    }

    func pushCommandSubstitution() -> ExecutionFailure? {
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

    func popCommandSubstitution() {
        commandSubstitutionDepth = max(0, commandSubstitutionDepth - 1)
    }
}
