import Foundation

extension BashSession {
    enum TrailingAction {
        case none
        case redirections([Redirection])
        case pipeline(String)
    }

    struct DelimitedKeywordMatch {
        var separatorIndex: String.Index
        var keywordIndex: String.Index
        var afterKeywordIndex: String.Index
    }

    static func findDelimitedKeyword(
        _ keyword: String,
        in commandLine: String,
        from startIndex: String.Index,
        end: String.Index? = nil
    ) -> DelimitedKeywordMatch? {
        var quote: QuoteKind = .none
        var index = startIndex
        let endIndex = end ?? commandLine.endIndex

        while index < endIndex {
            let character = commandLine[index]

            if character == "\\", quote != .single {
                let next = commandLine.index(after: index)
                if next < endIndex {
                    index = commandLine.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                index = commandLine.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                index = commandLine.index(after: index)
                continue
            }

            if quote == .none, character == ";" || character == "\n" {
                var cursor = commandLine.index(after: index)
                while cursor < endIndex, commandLine[cursor].isWhitespace {
                    cursor = commandLine.index(after: cursor)
                }
                guard cursor < endIndex else {
                    return nil
                }

                guard commandLine[cursor...].hasPrefix(keyword) else {
                    index = commandLine.index(after: index)
                    continue
                }

                let afterKeyword = commandLine.index(
                    cursor,
                    offsetBy: keyword.count
                )
                if afterKeyword < commandLine.endIndex,
                   Self.isIdentifierCharacter(commandLine[afterKeyword]) {
                    index = commandLine.index(after: index)
                    continue
                }

                return DelimitedKeywordMatch(
                    separatorIndex: index,
                    keywordIndex: cursor,
                    afterKeywordIndex: afterKeyword
                )
            }

            index = commandLine.index(after: index)
        }

        return nil
    }

    static func findFirstDelimitedKeyword(
        _ keywords: [String],
        in commandLine: String,
        from startIndex: String.Index,
        end: String.Index? = nil
    ) -> (keyword: String, match: DelimitedKeywordMatch)? {
        var best: (keyword: String, match: DelimitedKeywordMatch)?
        for keyword in keywords {
            guard let match = findDelimitedKeyword(
                keyword,
                in: commandLine,
                from: startIndex,
                end: end
            ) else {
                continue
            }

            if let currentBest = best {
                if match.separatorIndex < currentBest.match.separatorIndex {
                    best = (keyword, match)
                }
            } else {
                best = (keyword, match)
            }
        }
        return best
    }

    static func findKeywordTokenRange(
        _ keyword: String,
        in value: String,
        from start: String.Index
    ) -> Range<String.Index>? {
        var quote: QuoteKind = .none
        var index = start

        while index < value.endIndex {
            let character = value[index]

            if character == "\\", quote != .single {
                let next = value.index(after: index)
                if next < value.endIndex {
                    index = value.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                index = value.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                index = value.index(after: index)
                continue
            }

            if quote == .none, value[index...].hasPrefix(keyword) {
                let afterKeyword = value.index(index, offsetBy: keyword.count)
                let beforeBoundary: Bool
                if index == value.startIndex {
                    beforeBoundary = true
                } else {
                    let previous = value[value.index(before: index)]
                    beforeBoundary = isKeywordBoundaryCharacter(previous)
                }

                let afterBoundary: Bool
                if afterKeyword == value.endIndex {
                    afterBoundary = true
                } else {
                    afterBoundary = isKeywordBoundaryCharacter(value[afterKeyword])
                }

                if beforeBoundary, afterBoundary {
                    return index..<afterKeyword
                }
            }

            index = value.index(after: index)
        }

        return nil
    }

    static func isKeywordBoundaryCharacter(_ character: Character) -> Bool {
        character.isWhitespace || character == ";" || character == "(" || character == ")"
    }

    static func parseTrailingAction(
        from trailing: String,
        context: String
    ) -> Result<TrailingAction, ShellError> {
        let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success(.none)
        }

        if trimmed.hasPrefix("|") {
            let tail = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty else {
                return .failure(.parserError("\(context): expected command after '|'"))
            }
            return .success(.pipeline(tail))
        }

        switch parseRedirections(from: trimmed, context: context) {
        case let .success(redirections):
            return .success(.redirections(redirections))
        case let .failure(error):
            return .failure(error)
        }
    }

    static func parseRedirections(
        from trailing: String,
        context: String
    ) -> Result<[Redirection], ShellError> {
        let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .success([])
        }

        do {
            let parsed = try ShellParser.parse("true \(trimmed)")
            guard parsed.segments.count == 1,
                  let segment = parsed.segments.first,
                  segment.connector == nil,
                  segment.pipeline.count == 1,
                  !segment.runInBackground,
                  segment.pipeline[0].words.count == 1,
                  segment.pipeline[0].words[0].rawValue == "true" else {
                return .failure(
                    .parserError("\(context): unsupported trailing syntax")
                )
            }
            return .success(segment.pipeline[0].redirections)
        } catch let shellError as ShellError {
            return .failure(shellError)
        } catch {
            return .failure(.parserError("\(error)"))
        }
    }

    static func skipWhitespace(
        in commandLine: String,
        index: inout String.Index
    ) {
        while index < commandLine.endIndex, commandLine[index].isWhitespace {
            index = commandLine.index(after: index)
        }
    }

    static func readIdentifier(
        in commandLine: String,
        index: inout String.Index
    ) -> String? {
        guard index < commandLine.endIndex else {
            return nil
        }

        let first = commandLine[index]
        guard first == "_" || first.isLetter else {
            return nil
        }

        var value = String(first)
        index = commandLine.index(after: index)
        while index < commandLine.endIndex,
              isIdentifierCharacter(commandLine[index]) {
            value.append(commandLine[index])
            index = commandLine.index(after: index)
        }
        return value
    }

    static func consumeLiteral(
        _ literal: Character,
        in commandLine: String,
        index: inout String.Index
    ) -> Bool {
        guard index < commandLine.endIndex,
              commandLine[index] == literal else {
            return false
        }
        index = commandLine.index(after: index)
        return true
    }

    static func consumeKeyword(
        _ keyword: String,
        in commandLine: String,
        index: inout String.Index
    ) -> Bool {
        guard commandLine[index...].hasPrefix(keyword) else {
            return false
        }

        let end = commandLine.index(index, offsetBy: keyword.count)
        if end < commandLine.endIndex,
           isIdentifierCharacter(commandLine[end]) {
            return false
        }

        index = end
        return true
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    static func isValidIdentifierName(_ value: String) -> Bool {
        guard let first = value.first, first == "_" || first.isLetter else {
            return false
        }
        return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}
