import Foundation

package enum BraceExpansion {
    package static func expand(_ value: String) -> [String] {
        guard let expression = firstExpandableExpression(in: value) else {
            return [value]
        }

        let prefix = String(value[..<expression.open])
        let suffixStart = value.index(after: expression.close)
        let suffix = String(value[suffixStart...])

        var expanded: [String] = []
        for option in expression.options {
            for tail in expand(suffix) {
                expanded.append(prefix + option + tail)
            }
        }
        return expanded.isEmpty ? [value] : expanded
    }

    private struct Expression {
        let open: String.Index
        let close: String.Index
        let options: [String]
    }

    private static func firstExpandableExpression(in value: String) -> Expression? {
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "{" else {
                index = value.index(after: index)
                continue
            }

            if index > value.startIndex, value[value.index(before: index)] == "$" {
                index = value.index(after: index)
                continue
            }

            guard let close = matchingBrace(in: value, open: index) else {
                return nil
            }

            let bodyStart = value.index(after: index)
            let body = String(value[bodyStart..<close])
            if let options = expandOptions(from: body) {
                return Expression(open: index, close: close, options: options)
            }

            index = value.index(after: index)
        }

        return nil
    }

    private static func matchingBrace(in value: String, open: String.Index) -> String.Index? {
        var depth = 0
        var index = open
        while index < value.endIndex {
            if value[index] == "{" {
                depth += 1
            } else if value[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func expandOptions(from body: String) -> [String]? {
        if let range = rangeOptions(from: body) {
            return range
        }

        let commaParts = splitTopLevelCommas(body)
        guard commaParts.count > 1 else {
            return nil
        }
        return commaParts
    }

    private static func splitTopLevelCommas(_ value: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0

        for character in value {
            if character == "{" {
                depth += 1
                current.append(character)
            } else if character == "}" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character == ",", depth == 0 {
                parts.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }

        parts.append(current)
        return parts
    }

    private static func rangeOptions(from body: String) -> [String]? {
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count == 3, pieces[1].isEmpty else {
            return nil
        }

        let start = pieces[0]
        let end = pieces[2]

        if let startInt = Int(start), let endInt = Int(end) {
            let width = shouldPreserveWidth(start, end) ? max(start.count, end.count) : 0
            let step = startInt <= endInt ? 1 : -1
            var output: [String] = []
            var value = startInt
            while true {
                output.append(formatNumber(value, width: width))
                if value == endInt {
                    break
                }
                value += step
            }
            return output
        }

        guard start.count == 1,
              end.count == 1,
              let startScalar = start.unicodeScalars.first,
              let endScalar = end.unicodeScalars.first,
              isAsciiLetter(startScalar),
              isAsciiLetter(endScalar) else {
            return nil
        }

        let step: Int32 = startScalar.value <= endScalar.value ? 1 : -1
        var output: [String] = []
        var value = Int32(startScalar.value)
        let target = Int32(endScalar.value)
        while true {
            if let scalar = UnicodeScalar(Int(value)) {
                output.append(String(Character(scalar)))
            }
            if value == target {
                break
            }
            value += step
        }
        return output
    }

    private static func shouldPreserveWidth(_ start: String, _ end: String) -> Bool {
        start.hasPrefix("0") || end.hasPrefix("0") || start.hasPrefix("-0") || end.hasPrefix("-0")
    }

    private static func formatNumber(_ value: Int, width: Int) -> String {
        guard width > 0 else {
            return String(value)
        }

        let sign = value < 0 ? "-" : ""
        let magnitude = String(abs(value))
        let padding = String(repeating: "0", count: max(0, width - sign.count - magnitude.count))
        return sign + padding + magnitude
    }

    private static func isAsciiLetter(_ scalar: UnicodeScalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
}
