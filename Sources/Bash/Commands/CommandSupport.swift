import CryptoKit
import Foundation

enum CommandIO {
    static func decodeLines(_ data: Data) -> [String] {
        splitLines(String(decoding: data, as: UTF8.self))
    }

    static func decodeString(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    static func encode(_ string: String) -> Data {
        Data(string.utf8)
    }

    static func splitLines(_ string: String, dropTrailingTerminator: Bool = true) -> [String] {
        var lines = string
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        if dropTrailingTerminator, string.hasSuffix("\n"), lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}

enum CommandFS {
    static func readInputs(
        paths: [String],
        context: inout CommandContext
    ) async -> (contents: [String], hadError: Bool) {
        if paths.isEmpty {
            return ([CommandIO.decodeString(context.stdin)], false)
        }

        var contents: [String] = []
        var failed = false
        for path in paths {
            let resolved = context.resolvePath(path)
            do {
                let data = try await context.filesystem.readFile(path: resolved)
                contents.append(CommandIO.decodeString(data))
            } catch {
                context.writeStderr("\(path): \(error)\n")
                failed = true
            }
        }
        return (contents, failed)
    }

    static func recursiveSize(of path: String, filesystem: any ShellFilesystem) async throws -> UInt64 {
        let info = try await filesystem.stat(path: path)
        if !info.isDirectory {
            return info.size
        }

        var total: UInt64 = 0
        let children = try await filesystem.listDirectory(path: path)
        for child in children {
            total += try await recursiveSize(of: PathUtils.join(path, child.name), filesystem: filesystem)
        }
        return total
    }

    static func walk(path: String, filesystem: any ShellFilesystem) async throws -> [String] {
        var output = [path]
        let info = try await filesystem.stat(path: path)
        guard info.isDirectory else {
            return output
        }

        let children = try await filesystem.listDirectory(path: path)
        for child in children {
            let childPath = PathUtils.join(path, child.name)
            output.append(contentsOf: try await walk(path: childPath, filesystem: filesystem))
        }
        return output
    }

    static func parseFieldList(_ value: String) -> Set<Int> {
        var output: Set<Int> = []
        for part in value.split(separator: ",") {
            let token = String(part)
            if token.contains("-") {
                let pieces = token.split(separator: "-", maxSplits: 1).map(String.init)
                guard pieces.count == 2,
                      let low = Int(pieces[0]),
                      let high = Int(pieces[1]),
                      low > 0,
                      high >= low else {
                    continue
                }
                for value in low...high {
                    output.insert(value)
                }
            } else if let numeric = Int(token), numeric > 0 {
                output.insert(numeric)
            }
        }
        return output
    }

    static func wildcardMatch(pattern: String, value: String) -> Bool {
        let regexString = PathUtils.globToRegex(pattern)
        guard let regex = try? NSRegularExpression(pattern: regexString) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}

enum CommandText {
    static func isLikelyText(_ data: Data) -> Bool {
        if data.isEmpty {
            return true
        }

        for byte in data {
            if byte == 0 {
                return false
            }

            if byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue
            }

            if byte < 0x20 || byte > 0x7E {
                return false
            }
        }

        return true
    }
}

enum CommandHash {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
