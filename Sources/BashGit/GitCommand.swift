import ArgumentParser
import Foundation
import BashCore

public struct GitCommand: BuiltinCommand {
    public struct Options: ParsableArguments {
        @Argument(parsing: .captureForPassthrough, help: "git arguments")
        public var arguments: [String] = []

        public init() {}
    }

    public static let name = "git"
    public static let overview = "Run basic git operations using an in-process libgit2 backend"

    public static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let result = await GitEngine.run(arguments: options.arguments, context: &context)
        if !result.stdout.isEmpty {
            context.writeStdout(result.stdout)
        }
        if !result.stderr.isEmpty {
            context.writeStderr(result.stderr)
        }
        return result.exitCode
    }
}
