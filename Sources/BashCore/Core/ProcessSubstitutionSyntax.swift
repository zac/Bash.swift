package enum ProcessSubstitutionKind: Sendable {
    case input
    case output
}

package struct ProcessSubstitutionCapture: Sendable {
    package let kind: ProcessSubstitutionKind
    package let raw: String
    package let content: String
    package let endIndex: String.Index
}

package enum ProcessSubstitutionSyntax {
    package static func capture(
        in text: String,
        from start: String.Index
    ) throws -> ProcessSubstitutionCapture? {
        guard start < text.endIndex else {
            return nil
        }

        let kind: ProcessSubstitutionKind
        if text[start] == "<" {
            kind = .input
        } else if text[start] == ">" {
            kind = .output
        } else {
            return nil
        }

        let open = text.index(after: start)
        guard open < text.endIndex, text[open] == "(" else {
            return nil
        }

        var index = text.index(after: open)
        let contentStart = index
        var depth = 1
        var quote: QuoteKind = .none

        while index < text.endIndex {
            let character = text[index]

            if character == "\\", quote != .single {
                let next = text.index(after: index)
                index = next < text.endIndex ? text.index(after: next) : next
                continue
            }

            if character == "'", quote != .double {
                quote = quote == .single ? .none : .single
                index = text.index(after: index)
                continue
            }

            if character == "\"", quote != .single {
                quote = quote == .double ? .none : .double
                index = text.index(after: index)
                continue
            }

            if quote == .none {
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: index)
                        return ProcessSubstitutionCapture(
                            kind: kind,
                            raw: String(text[start..<end]),
                            content: String(text[contentStart..<index]),
                            endIndex: end
                        )
                    }
                }
            }

            index = text.index(after: index)
        }

        throw ShellError.parserError("unterminated process substitution")
    }
}
