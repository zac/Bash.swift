import Foundation

enum PathUtils {
    static func normalize(path: String, currentDirectory: String) -> String {
        if path.isEmpty {
            return currentDirectory
        }

        let base: [String]
        if path.hasPrefix("/") {
            base = []
        } else {
            base = splitComponents(currentDirectory)
        }

        var parts = base
        for piece in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".":
                continue
            case "..":
                if !parts.isEmpty {
                    parts.removeLast()
                }
            default:
                parts.append(String(piece))
            }
        }

        return "/" + parts.joined(separator: "/")
    }

    static func splitComponents(_ absolutePath: String) -> [String] {
        absolutePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func basename(_ path: String) -> String {
        let normalized = path == "/" ? "/" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalized == "/" || normalized.isEmpty {
            return "/"
        }
        return normalized.split(separator: "/").last.map(String.init) ?? "/"
    }

    static func dirname(_ path: String) -> String {
        let normalized = normalize(path: path, currentDirectory: "/")
        if normalized == "/" {
            return "/"
        }

        var parts = splitComponents(normalized)
        _ = parts.popLast()
        if parts.isEmpty {
            return "/"
        }
        return "/" + parts.joined(separator: "/")
    }

    static func join(_ lhs: String, _ rhs: String) -> String {
        if rhs.hasPrefix("/") {
            return normalize(path: rhs, currentDirectory: "/")
        }

        let separator = lhs.hasSuffix("/") ? "" : "/"
        return normalize(path: lhs + separator + rhs, currentDirectory: "/")
    }

    static func containsGlob(_ token: String) -> Bool {
        token.contains("*") || token.contains("?") || token.contains("[")
    }

    static func globToRegex(_ pattern: String) -> String {
        var regex = "^"
        var index = pattern.startIndex

        while index < pattern.endIndex {
            let char = pattern[index]
            if char == "*" {
                regex += ".*"
            } else if char == "?" {
                regex += "."
            } else if char == "[" {
                if let closeIndex = pattern[index...].firstIndex(of: "]") {
                    let range = pattern.index(after: index)..<closeIndex
                    regex += "[" + String(pattern[range]) + "]"
                    index = closeIndex
                } else {
                    regex += "\\["
                }
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
            }
            index = pattern.index(after: index)
        }

        regex += "$"
        return regex
    }
}
