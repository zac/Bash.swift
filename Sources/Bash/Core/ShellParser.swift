import Foundation

enum RedirectionType: Sendable {
    case stdin
    case stdoutTruncate
    case stdoutAppend
    case stderrTruncate
    case stderrAppend
    case stderrToStdout
    case stdoutAndErrTruncate
    case stdoutAndErrAppend
}

struct Redirection: Sendable {
    let type: RedirectionType
    let target: ShellWord?
}

struct ParsedCommand: Sendable {
    var words: [ShellWord]
    var redirections: [Redirection]
}

enum ChainOperator: Sendable {
    case sequence
    case and
    case or
}

struct ParsedSegment: Sendable {
    let connector: ChainOperator?
    let pipeline: [ParsedCommand]
    let runInBackground: Bool
}

struct ParsedLine: Sendable {
    let segments: [ParsedSegment]
}

enum ShellParser {
    static func parse(_ commandLine: String) throws -> ParsedLine {
        let tokens = try ShellLexer.tokenize(commandLine)
        guard !tokens.isEmpty else {
            return ParsedLine(segments: [])
        }

        var index = 0
        var segments: [ParsedSegment] = []
        var nextConnector: ChainOperator? = nil

        while index < tokens.count {
            let connector = nextConnector
            let pipeline = try parsePipeline(tokens: tokens, index: &index)
            var runInBackground = false

            guard index < tokens.count else {
                segments.append(
                    ParsedSegment(
                        connector: connector,
                        pipeline: pipeline,
                        runInBackground: runInBackground
                    )
                )
                break
            }

            let operatorToken = tokens[index]
            switch operatorToken {
            case .semicolon:
                nextConnector = .sequence
                index += 1
            case .background:
                runInBackground = true
                nextConnector = .sequence
                index += 1
            case .andIf:
                nextConnector = .and
                index += 1
            case .orIf:
                nextConnector = .or
                index += 1
            default:
                throw ShellError.parserError("unexpected token in command chain")
            }

            segments.append(
                ParsedSegment(
                    connector: connector,
                    pipeline: pipeline,
                    runInBackground: runInBackground
                )
            )

            if index == tokens.count {
                if case .semicolon = operatorToken {
                    break
                }
                if case .background = operatorToken {
                    break
                }
                throw ShellError.parserError("trailing chain operator")
            }
        }

        return ParsedLine(segments: segments)
    }

    private static func parsePipeline(tokens: [LexToken], index: inout Int) throws -> [ParsedCommand] {
        var commands = [try parseCommand(tokens: tokens, index: &index)]

        while index < tokens.count {
            if case .pipe = tokens[index] {
                index += 1
                commands.append(try parseCommand(tokens: tokens, index: &index))
            } else {
                break
            }
        }

        return commands
    }

    private static func parseCommand(tokens: [LexToken], index: inout Int) throws -> ParsedCommand {
        var words: [ShellWord] = []
        var redirections: [Redirection] = []

        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case let .word(word):
                words.append(word)
                index += 1
            case .redirOut:
                index += 1
                let target = try takeRedirectionTarget(tokens: tokens, index: &index)
                redirections.append(Redirection(type: .stdoutTruncate, target: target))
            case .redirAppend:
                index += 1
                let target = try takeRedirectionTarget(tokens: tokens, index: &index)
                redirections.append(Redirection(type: .stdoutAppend, target: target))
            case .redirIn:
                index += 1
                let target = try takeRedirectionTarget(tokens: tokens, index: &index)
                redirections.append(Redirection(type: .stdin, target: target))
            case .redirErrOut:
                index += 1
                let target = try takeRedirectionTarget(tokens: tokens, index: &index)
                redirections.append(Redirection(type: .stderrTruncate, target: target))
            case .redirErrAppend:
                index += 1
                let target = try takeRedirectionTarget(tokens: tokens, index: &index)
                redirections.append(Redirection(type: .stderrAppend, target: target))
            case .redirErrToOut:
                index += 1
                redirections.append(Redirection(type: .stderrToStdout, target: nil))
            case .redirAllOut:
                index += 1
                let target = try takeRedirectionTarget(tokens: tokens, index: &index)
                redirections.append(Redirection(type: .stdoutAndErrTruncate, target: target))
            case .redirAllAppend:
                index += 1
                let target = try takeRedirectionTarget(tokens: tokens, index: &index)
                redirections.append(Redirection(type: .stdoutAndErrAppend, target: target))
            case .pipe, .semicolon, .background, .andIf, .orIf:
                if words.isEmpty {
                    throw ShellError.parserError("expected command before operator")
                }
                return ParsedCommand(words: words, redirections: redirections)
            }
        }

        if words.isEmpty {
            throw ShellError.parserError("expected command")
        }

        return ParsedCommand(words: words, redirections: redirections)
    }

    private static func takeRedirectionTarget(tokens: [LexToken], index: inout Int) throws -> ShellWord {
        guard index < tokens.count else {
            throw ShellError.parserError("missing redirection target")
        }

        if case let .word(word) = tokens[index] {
            index += 1
            return word
        }

        throw ShellError.parserError("missing redirection target")
    }
}
