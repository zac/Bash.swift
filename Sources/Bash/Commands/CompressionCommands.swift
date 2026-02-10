import ArgumentParser
import Compression
import Foundation
#if canImport(zlib)
import zlib
#endif

struct GzipCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.customShort("d"), .customLong("decompress")], help: "Decompress")
        var decompress = false

        @Flag(name: .short, help: "Write output on standard output")
        var c = false

        @Flag(name: .short, help: "Keep input files")
        var k = false

        @Flag(name: .short, help: "Force overwrite of output files")
        var f = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "gzip"
    static let overview = "Compress or decompress files"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.decompress {
            return await CompressionCommandRunner.gunzip(
                context: &context,
                files: options.files,
                writeToStdout: options.c,
                keepInput: options.k,
                forceOverwrite: options.f,
                commandName: name
            )
        }

        return await CompressionCommandRunner.gzip(
            context: &context,
            files: options.files,
            writeToStdout: options.c,
            keepInput: options.k,
            forceOverwrite: options.f,
            commandName: name
        )
    }
}

struct GunzipCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Write output on standard output")
        var c = false

        @Flag(name: .short, help: "Keep input files")
        var k = false

        @Flag(name: .short, help: "Force overwrite of output files")
        var f = false

        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "gunzip"
    static let overview = "Decompress files in gzip format"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await CompressionCommandRunner.gunzip(
            context: &context,
            files: options.files,
            writeToStdout: options.c,
            keepInput: options.k,
            forceOverwrite: options.f,
            commandName: name
        )
    }
}

struct ZcatCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Argument(help: "Optional files")
        var files: [String] = []
    }

    static let name = "zcat"
    static let overview = "Decompress gzip files to standard output"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        await CompressionCommandRunner.gunzip(
            context: &context,
            files: options.files,
            writeToStdout: true,
            keepInput: true,
            forceOverwrite: true,
            commandName: name
        )
    }
}

struct ZipCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Recurse into directories")
        var r = false

        @Flag(name: [.customShort("0"), .customLong("store")], help: "Store only (no compression)")
        var storeOnly = false

        @Argument(help: "Archive path followed by input paths")
        var values: [String] = []
    }

    static let name = "zip"
    static let overview = "Create ZIP archives"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard options.values.count >= 2 else {
            context.writeStderr("zip: expected archive and at least one input path\n")
            return 2
        }

        let archivePath = context.resolvePath(options.values[0])
        let operands = Array(options.values.dropFirst())
        var entries: [ZipCodec.Entry] = []
        var seen = Set<String>()

        for operand in operands {
            let resolvedInputPath = context.resolvePath(operand)
            let archiveEntryPath = archivePathForOperand(operand, resolvedPath: resolvedInputPath)

            do {
                entries.append(
                    contentsOf: try await collectEntries(
                        virtualPath: resolvedInputPath,
                        archivePath: archiveEntryPath,
                        recursiveDirectories: options.r,
                        filesystem: context.filesystem,
                        seenPaths: &seen
                    )
                )
            } catch {
                context.writeStderr("zip: \(operand): \(error)\n")
                return 1
            }
        }

        do {
            let compression: ZipCodec.CompressionMethod = options.storeOnly ? .stored : .deflate
            let data = try ZipCodec.encode(entries: entries, compression: compression)
            try await context.filesystem.writeFile(path: archivePath, data: data, append: false)
            return 0
        } catch {
            context.writeStderr("zip: \(error)\n")
            return 1
        }
    }

    private static func collectEntries(
        virtualPath: String,
        archivePath: String,
        recursiveDirectories: Bool,
        filesystem: any ShellFilesystem,
        seenPaths: inout Set<String>
    ) async throws -> [ZipCodec.Entry] {
        let info = try await filesystem.stat(path: virtualPath)
        let cleanPath = ZipCodec.cleanEntryPath(archivePath)

        if info.isDirectory {
            guard recursiveDirectories else {
                throw ShellError.unsupported("is a directory (use -r): \(archivePath)")
            }

            let directoryPath = cleanPath.hasSuffix("/") ? cleanPath : cleanPath + "/"
            var output: [ZipCodec.Entry] = []
            if seenPaths.insert(directoryPath).inserted {
                output.append(
                    .directory(
                        path: directoryPath,
                        mode: info.permissions,
                        modificationTime: modificationTime(info.modificationDate)
                    )
                )
            }

            let children = try await filesystem.listDirectory(path: virtualPath).sorted { $0.name < $1.name }
            for child in children {
                let childVirtualPath = PathUtils.join(virtualPath, child.name)
                let childArchivePath = directoryPath + child.name
                output.append(
                    contentsOf: try await collectEntries(
                        virtualPath: childVirtualPath,
                        archivePath: childArchivePath,
                        recursiveDirectories: true,
                        filesystem: filesystem,
                        seenPaths: &seenPaths
                    )
                )
            }
            return output
        }

        if seenPaths.insert(cleanPath).inserted {
            let data = try await filesystem.readFile(path: virtualPath)
            return [
                .file(
                    path: cleanPath,
                    data: data,
                    mode: info.permissions,
                    modificationTime: modificationTime(info.modificationDate)
                )
            ]
        }
        return []
    }

    private static func archivePathForOperand(_ operand: String, resolvedPath: String) -> String {
        let normalizedOperand = PathUtils.normalize(path: operand, currentDirectory: "/")
        var archivePath = String(normalizedOperand.dropFirst())
        if archivePath.isEmpty {
            archivePath = PathUtils.basename(resolvedPath)
        }
        if archivePath.isEmpty {
            archivePath = "root"
        }
        return archivePath
    }

    private static func modificationTime(_ date: Date?) -> Int {
        Int((date ?? Date()).timeIntervalSince1970)
    }
}

struct UnzipCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "List archive contents")
        var l = false

        @Flag(name: .short, help: "Extract files to stdout")
        var p = false

        @Flag(name: .short, help: "Overwrite existing files")
        var o = false

        @Option(name: .customShort("d"), help: "Extract into directory")
        var d: String?

        @Argument(help: "Archive path and optional entry filters")
        var values: [String] = []
    }

    static let name = "unzip"
    static let overview = "Extract or list ZIP archives"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard let archiveArg = options.values.first else {
            context.writeStderr("unzip: expected archive path\n")
            return 2
        }

        if options.l && options.p {
            context.writeStderr("unzip: cannot combine -l and -p\n")
            return 2
        }

        let filters = Array(options.values.dropFirst())
        let archivePath = context.resolvePath(archiveArg)

        let entries: [ZipCodec.Entry]
        do {
            let data = try await context.filesystem.readFile(path: archivePath)
            entries = try ZipCodec.decode(data: data)
        } catch {
            context.writeStderr("unzip: \(error)\n")
            return 1
        }

        let selectedEntries = filterEntries(entries: entries, filters: filters)

        if options.l {
            for entry in selectedEntries {
                context.writeStdout("\(entry.path)\n")
            }
            return 0
        }

        if options.p {
            for entry in selectedEntries {
                if case let .file(data) = entry.kind {
                    context.stdout.append(data)
                }
            }
            return 0
        }

        let destinationRoot = options.d.map(context.resolvePath) ?? context.currentDirectory
        do {
            try await context.filesystem.createDirectory(path: destinationRoot, recursive: true)
        } catch {
            context.writeStderr("unzip: \(error)\n")
            return 1
        }

        var failed = false
        for entry in selectedEntries {
            let outputPath = PathUtils.normalize(path: entry.path, currentDirectory: destinationRoot)

            do {
                switch entry.kind {
                case .directory:
                    try await context.filesystem.createDirectory(path: outputPath, recursive: true)
                    try? await context.filesystem.setPermissions(path: outputPath, permissions: entry.mode)
                case let .file(data):
                    let parent = PathUtils.dirname(outputPath)
                    try await context.filesystem.createDirectory(path: parent, recursive: true)
                    if !options.o, await context.filesystem.exists(path: outputPath) {
                        context.writeStderr("unzip: \(PathUtils.basename(outputPath)): already exists\n")
                        failed = true
                        continue
                    }
                    try await context.filesystem.writeFile(path: outputPath, data: data, append: false)
                    try? await context.filesystem.setPermissions(path: outputPath, permissions: entry.mode)
                }
            } catch {
                context.writeStderr("unzip: \(entry.path): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    private static func filterEntries(entries: [ZipCodec.Entry], filters: [String]) -> [ZipCodec.Entry] {
        guard !filters.isEmpty else {
            return entries
        }

        let normalizedFilters = filters.map(normalizeFilterPath)
        return entries.filter { entry in
            let entryPath = normalizeFilterPath(entry.path)
            return normalizedFilters.contains { filter in
                entryPath == filter || entryPath.hasPrefix(filter + "/")
            }
        }
    }

    private static func normalizeFilterPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasPrefix("./") {
            value.removeFirst(2)
        }
        return value
    }
}

struct TarCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: .short, help: "Create a new archive")
        var c = false

        @Flag(name: .short, help: "Extract from an archive")
        var x = false

        @Flag(name: .short, help: "List archive contents")
        var t = false

        @Flag(name: .short, help: "Use gzip compression/decompression")
        var z = false

        @Option(name: .short, help: "Archive file")
        var f: String?

        @Option(name: .customShort("C"), help: "Change to directory")
        var C: String?

        @Argument(help: "Paths")
        var paths: [String] = []
    }

    static let name = "tar"
    static let overview = "Create, extract, and list tar archives"

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        let modeCount = [options.c, options.x, options.t].filter { $0 }.count
        guard modeCount == 1 else {
            context.writeStderr("tar: exactly one of -c, -x, or -t is required\n")
            return 2
        }

        guard let archiveArg = options.f, !archiveArg.isEmpty else {
            context.writeStderr("tar: archive file is required (-f)\n")
            return 2
        }

        if options.c {
            return await createArchive(context: &context, options: options, archiveArg: archiveArg)
        }
        if options.x {
            return await extractArchive(context: &context, options: options, archiveArg: archiveArg)
        }
        return await listArchive(context: &context, options: options, archiveArg: archiveArg)
    }

    private static func createArchive(
        context: inout CommandContext,
        options: Options,
        archiveArg: String
    ) async -> Int32 {
        guard !options.paths.isEmpty else {
            context.writeStderr("tar: refusing to create an empty archive\n")
            return 2
        }

        let baseDirectory = options.C.map(context.resolvePath) ?? context.currentDirectory

        var entries: [TarCodec.Entry] = []
        var seen = Set<String>()

        for operand in options.paths {
            let resolvedInputPath = PathUtils.normalize(path: operand, currentDirectory: baseDirectory)
            let archivePath = archivePathForOperand(operand, resolvedPath: resolvedInputPath)
            do {
                entries.append(
                    contentsOf: try await collectTarEntries(
                        virtualPath: resolvedInputPath,
                        archivePath: archivePath,
                        filesystem: context.filesystem,
                        seenPaths: &seen
                    )
                )
            } catch {
                context.writeStderr("tar: \(operand): \(error)\n")
                return 1
            }
        }

        do {
            let tarData = try TarCodec.encode(entries: entries)
            let outputData = options.z ? try GzipCodec.compress(tarData) : tarData
            let archivePath = context.resolvePath(archiveArg)
            try await context.filesystem.writeFile(path: archivePath, data: outputData, append: false)
            return 0
        } catch {
            context.writeStderr("tar: \(error)\n")
            return 1
        }
    }

    private static func listArchive(
        context: inout CommandContext,
        options: Options,
        archiveArg: String
    ) async -> Int32 {
        do {
            let entries = try await readTarEntries(context: &context, archiveArg: archiveArg, forceGzip: options.z)
            for entry in filterEntries(entries: entries, filters: options.paths) {
                context.writeStdout("\(entry.path)\n")
            }
            return 0
        } catch {
            context.writeStderr("tar: \(error)\n")
            return 1
        }
    }

    private static func extractArchive(
        context: inout CommandContext,
        options: Options,
        archiveArg: String
    ) async -> Int32 {
        do {
            let entries = try await readTarEntries(context: &context, archiveArg: archiveArg, forceGzip: options.z)
            let destinationRoot = options.C.map(context.resolvePath) ?? context.currentDirectory
            try await context.filesystem.createDirectory(path: destinationRoot, recursive: true)

            for entry in filterEntries(entries: entries, filters: options.paths) {
                let outputPath = PathUtils.normalize(path: entry.path, currentDirectory: destinationRoot)
                switch entry.kind {
                case .directory:
                    try await context.filesystem.createDirectory(path: outputPath, recursive: true)
                    try? await context.filesystem.setPermissions(path: outputPath, permissions: entry.mode)
                case let .file(data):
                    let parent = PathUtils.dirname(outputPath)
                    try await context.filesystem.createDirectory(path: parent, recursive: true)
                    try await context.filesystem.writeFile(path: outputPath, data: data, append: false)
                    try? await context.filesystem.setPermissions(path: outputPath, permissions: entry.mode)
                }
            }
            return 0
        } catch {
            context.writeStderr("tar: \(error)\n")
            return 1
        }
    }

    private static func readTarEntries(
        context: inout CommandContext,
        archiveArg: String,
        forceGzip: Bool
    ) async throws -> [TarCodec.Entry] {
        let archivePath = context.resolvePath(archiveArg)
        let archiveData = try await context.filesystem.readFile(path: archivePath)
        let isGzipData = GzipCodec.looksLikeGzip(archiveData)

        let tarData: Data
        if forceGzip || isGzipData {
            tarData = try GzipCodec.decompress(archiveData)
        } else {
            tarData = archiveData
        }

        return try TarCodec.decode(data: tarData)
    }

    private static func filterEntries(entries: [TarCodec.Entry], filters: [String]) -> [TarCodec.Entry] {
        guard !filters.isEmpty else {
            return entries
        }

        let normalizedFilters = filters.map(normalizeFilterPath)
        return entries.filter { entry in
            let entryPath = normalizeFilterPath(entry.path)
            return normalizedFilters.contains { filter in
                entryPath == filter || entryPath.hasPrefix(filter + "/")
            }
        }
    }

    private static func normalizeFilterPath(_ path: String) -> String {
        var value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if value.hasPrefix("./") {
            value.removeFirst(2)
        }
        return value
    }

    private static func archivePathForOperand(_ operand: String, resolvedPath: String) -> String {
        let normalizedOperand = PathUtils.normalize(path: operand, currentDirectory: "/")
        var archivePath = String(normalizedOperand.dropFirst())
        if archivePath.isEmpty {
            archivePath = PathUtils.basename(resolvedPath)
        }
        if archivePath.isEmpty {
            archivePath = "root"
        }
        return archivePath
    }

    private static func collectTarEntries(
        virtualPath: String,
        archivePath: String,
        filesystem: any ShellFilesystem,
        seenPaths: inout Set<String>
    ) async throws -> [TarCodec.Entry] {
        let info = try await filesystem.stat(path: virtualPath)
        let cleanPath = TarCodec.cleanArchivePath(archivePath)

        if info.isDirectory {
            let directoryPath = cleanPath.hasSuffix("/") ? cleanPath : cleanPath + "/"
            var output: [TarCodec.Entry] = []
            if seenPaths.insert(directoryPath).inserted {
                output.append(
                    .directory(
                        path: directoryPath,
                        mode: info.permissions,
                        modificationTime: modificationTime(info.modificationDate)
                    )
                )
            }

            let children = try await filesystem.listDirectory(path: virtualPath).sorted { $0.name < $1.name }
            for child in children {
                let childVirtualPath = PathUtils.join(virtualPath, child.name)
                let childArchivePath = directoryPath + child.name
                output.append(
                    contentsOf: try await collectTarEntries(
                        virtualPath: childVirtualPath,
                        archivePath: childArchivePath,
                        filesystem: filesystem,
                        seenPaths: &seenPaths
                    )
                )
            }
            return output
        }

        if seenPaths.insert(cleanPath).inserted {
            let data = try await filesystem.readFile(path: virtualPath)
            return [
                .file(
                    path: cleanPath,
                    data: data,
                    mode: info.permissions,
                    modificationTime: modificationTime(info.modificationDate)
                )
            ]
        }
        return []
    }

    private static func modificationTime(_ date: Date?) -> Int {
        Int((date ?? Date()).timeIntervalSince1970)
    }
}

private enum CompressionCommandRunner {
    static func gzip(
        context: inout CommandContext,
        files: [String],
        writeToStdout: Bool,
        keepInput: Bool,
        forceOverwrite: Bool,
        commandName: String
    ) async -> Int32 {
        if files.isEmpty {
            do {
                context.stdout.append(try GzipCodec.compress(context.stdin))
                return 0
            } catch {
                context.writeStderr("\(commandName): \(error)\n")
                return 1
            }
        }

        var failed = false
        for file in files {
            let sourcePath = context.resolvePath(file)
            do {
                let input = try await context.filesystem.readFile(path: sourcePath)
                let output = try GzipCodec.compress(input)

                if writeToStdout {
                    context.stdout.append(output)
                    continue
                }

                let destinationPath = sourcePath + ".gz"
                if !forceOverwrite, await context.filesystem.exists(path: destinationPath) {
                    context.writeStderr("\(commandName): \(file).gz: already exists\n")
                    failed = true
                    continue
                }

                try await context.filesystem.writeFile(path: destinationPath, data: output, append: false)
                if !keepInput {
                    try await context.filesystem.remove(path: sourcePath, recursive: false)
                }
            } catch {
                context.writeStderr("\(commandName): \(file): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    static func gunzip(
        context: inout CommandContext,
        files: [String],
        writeToStdout: Bool,
        keepInput: Bool,
        forceOverwrite: Bool,
        commandName: String
    ) async -> Int32 {
        if files.isEmpty {
            do {
                context.stdout.append(try GzipCodec.decompress(context.stdin))
                return 0
            } catch {
                context.writeStderr("\(commandName): \(error)\n")
                return 1
            }
        }

        var failed = false
        for file in files {
            let sourcePath = context.resolvePath(file)
            do {
                let input = try await context.filesystem.readFile(path: sourcePath)
                let output = try GzipCodec.decompress(input)

                if writeToStdout {
                    context.stdout.append(output)
                    continue
                }

                let destinationPath = gunzipOutputPath(for: sourcePath)
                if !forceOverwrite, await context.filesystem.exists(path: destinationPath) {
                    context.writeStderr("\(commandName): \(PathUtils.basename(destinationPath)): already exists\n")
                    failed = true
                    continue
                }

                try await context.filesystem.writeFile(path: destinationPath, data: output, append: false)
                if !keepInput {
                    try await context.filesystem.remove(path: sourcePath, recursive: false)
                }
            } catch {
                context.writeStderr("\(commandName): \(file): \(error)\n")
                failed = true
            }
        }

        return failed ? 1 : 0
    }

    private static func gunzipOutputPath(for sourcePath: String) -> String {
        if sourcePath.hasSuffix(".tgz") {
            return String(sourcePath.dropLast(4)) + ".tar"
        }
        if sourcePath.hasSuffix(".gz") {
            return String(sourcePath.dropLast(3))
        }
        return sourcePath + ".out"
    }
}

private enum GzipCodec {
    static func compress(_ input: Data) throws -> Data {
        let compressedPayload = try DeflateCodec.compress(input)
        var output = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        output.append(compressedPayload)

        appendLittleEndianUInt32(CRC32.checksum(input), to: &output)
        appendLittleEndianUInt32(UInt32(truncatingIfNeeded: input.count), to: &output)
        return output
    }

    static func decompress(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        guard bytes.count >= 18 else {
            throw ShellError.unsupported("invalid gzip stream")
        }
        guard looksLikeGzip(input) else {
            throw ShellError.unsupported("not in gzip format")
        }

        let flags = bytes[3]
        var index = 10

        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            let extraLength = Int(UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8))
            index += 2
            guard index + extraLength <= bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += extraLength
        }

        if flags & 0x08 != 0 {
            while index < bytes.count, bytes[index] != 0x00 {
                index += 1
            }
            guard index < bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += 1
        }

        if flags & 0x10 != 0 {
            while index < bytes.count, bytes[index] != 0x00 {
                index += 1
            }
            guard index < bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += 1
        }

        if flags & 0x02 != 0 {
            guard index + 2 <= bytes.count else {
                throw ShellError.unsupported("invalid gzip header")
            }
            index += 2
        }

        guard index <= bytes.count - 8 else {
            throw ShellError.unsupported("invalid gzip stream")
        }

        let payload = Data(bytes[index..<(bytes.count - 8)])
        let expectedCRC = littleEndianUInt32(from: bytes, at: bytes.count - 8)
        let expectedSize = littleEndianUInt32(from: bytes, at: bytes.count - 4)

        let output = try DeflateCodec.decompress(payload)
        guard CRC32.checksum(output) == expectedCRC else {
            throw ShellError.unsupported("gzip CRC mismatch")
        }
        guard UInt32(truncatingIfNeeded: output.count) == expectedSize else {
            throw ShellError.unsupported("gzip size mismatch")
        }

        return output
    }

    static func looksLikeGzip(_ data: Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }
        return data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    private static func littleEndianUInt32(from bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | (UInt32(bytes[index + 1]) << 8)
            | (UInt32(bytes[index + 2]) << 16)
            | (UInt32(bytes[index + 3]) << 24)
    }

    private static func appendLittleEndianUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }
}

private enum DeflateCodec {
    static func compress(_ input: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.compress, using: .zlib) { chunk in
            if let chunk {
                output.append(chunk)
            }
        }
        try filter.write(input)
        try filter.finalize()
        return output
    }

    static func decompress(_ input: Data) throws -> Data {
        var output = Data()
        let filter = try OutputFilter(.decompress, using: .zlib) { chunk in
            if let chunk {
                output.append(chunk)
            }
        }
        try filter.write(input)
        try filter.finalize()
        return output
    }
}

private enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { value in
            var c = UInt32(value)
            for _ in 0..<8 {
                if c & 1 == 1 {
                    c = 0xedb88320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return ~crc
    }
}

private enum ZipCodec {
    enum CompressionMethod {
        case stored
        case deflate
    }

    struct Entry {
        enum Kind {
            case file(Data)
            case directory
        }

        let path: String
        let kind: Kind
        let mode: Int
        let modificationTime: Int

        static func file(path: String, data: Data, mode: Int, modificationTime: Int) -> Entry {
            Entry(path: path, kind: .file(data), mode: mode, modificationTime: modificationTime)
        }

        static func directory(path: String, mode: Int, modificationTime: Int) -> Entry {
            Entry(path: path, kind: .directory, mode: mode, modificationTime: modificationTime)
        }
    }

    static func cleanEntryPath(_ path: String) -> String {
        var output = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if output.hasPrefix("./") {
            output.removeFirst(2)
        }
        if output.isEmpty {
            output = "root"
        }
        return output
    }

    static func encode(entries: [Entry], compression: CompressionMethod) throws -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for entry in entries {
            entryCount = entryCount &+ 1
            let normalizedPath = normalizePathForEntry(entry)
            let nameBytes = [UInt8](normalizedPath.utf8)
            guard nameBytes.count <= Int(UInt16.max) else {
                throw ShellError.unsupported("zip entry name too long: \(normalizedPath)")
            }

            let (dosTime, dosDate) = dosTimestamp(from: entry.modificationTime)
            let localHeaderOffset = UInt32(truncatingIfNeeded: archive.count)

            let rawData: Data
            switch entry.kind {
            case let .file(data):
                rawData = data
            case .directory:
                rawData = Data()
            }

            let method: UInt16
            let compressedData: Data
            switch entry.kind {
            case .directory:
                method = 0
                compressedData = Data()
            case .file:
                switch compression {
                case .stored:
                    method = 0
                    compressedData = rawData
                case .deflate:
                    method = 8
                    compressedData = try RawDeflateCodec.compress(rawData)
                }
            }

            let crc = CRC32.checksum(rawData)
            let compressedSize = UInt32(truncatingIfNeeded: compressedData.count)
            let uncompressedSize = UInt32(truncatingIfNeeded: rawData.count)

            appendUInt32LE(0x04034b50, to: &archive)
            appendUInt16LE(20, to: &archive) // version needed
            appendUInt16LE(0, to: &archive) // flags
            appendUInt16LE(method, to: &archive)
            appendUInt16LE(dosTime, to: &archive)
            appendUInt16LE(dosDate, to: &archive)
            appendUInt32LE(crc, to: &archive)
            appendUInt32LE(compressedSize, to: &archive)
            appendUInt32LE(uncompressedSize, to: &archive)
            appendUInt16LE(UInt16(nameBytes.count), to: &archive)
            appendUInt16LE(0, to: &archive) // extra length
            archive.append(contentsOf: nameBytes)
            archive.append(compressedData)

            appendUInt32LE(0x02014b50, to: &centralDirectory)
            appendUInt16LE(20, to: &centralDirectory) // version made by
            appendUInt16LE(20, to: &centralDirectory) // version needed
            appendUInt16LE(0, to: &centralDirectory) // flags
            appendUInt16LE(method, to: &centralDirectory)
            appendUInt16LE(dosTime, to: &centralDirectory)
            appendUInt16LE(dosDate, to: &centralDirectory)
            appendUInt32LE(crc, to: &centralDirectory)
            appendUInt32LE(compressedSize, to: &centralDirectory)
            appendUInt32LE(uncompressedSize, to: &centralDirectory)
            appendUInt16LE(UInt16(nameBytes.count), to: &centralDirectory)
            appendUInt16LE(0, to: &centralDirectory) // extra length
            appendUInt16LE(0, to: &centralDirectory) // comment length
            appendUInt16LE(0, to: &centralDirectory) // disk number
            appendUInt16LE(0, to: &centralDirectory) // internal attrs
            appendUInt32LE(externalAttributes(for: entry), to: &centralDirectory)
            appendUInt32LE(localHeaderOffset, to: &centralDirectory)
            centralDirectory.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(truncatingIfNeeded: archive.count)
        archive.append(centralDirectory)
        let centralSize = UInt32(truncatingIfNeeded: centralDirectory.count)

        appendUInt32LE(0x06054b50, to: &archive)
        appendUInt16LE(0, to: &archive) // current disk
        appendUInt16LE(0, to: &archive) // central dir disk
        appendUInt16LE(entryCount, to: &archive)
        appendUInt16LE(entryCount, to: &archive)
        appendUInt32LE(centralSize, to: &archive)
        appendUInt32LE(centralOffset, to: &archive)
        appendUInt16LE(0, to: &archive) // comment length

        return archive
    }

    static func decode(data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard let eocdOffset = findEOCDOffset(bytes) else {
            throw ShellError.unsupported("invalid zip archive")
        }
        guard eocdOffset + 22 <= bytes.count else {
            throw ShellError.unsupported("invalid zip archive")
        }

        let entryCount = readUInt16LE(bytes, at: eocdOffset + 10)
        let centralSize = Int(readUInt32LE(bytes, at: eocdOffset + 12))
        let centralOffset = Int(readUInt32LE(bytes, at: eocdOffset + 16))
        guard centralOffset + centralSize <= bytes.count else {
            throw ShellError.unsupported("invalid zip central directory")
        }

        var entries: [Entry] = []
        var cursor = centralOffset
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count else {
                throw ShellError.unsupported("invalid zip central entry")
            }
            guard readUInt32LE(bytes, at: cursor) == 0x02014b50 else {
                throw ShellError.unsupported("invalid zip central header")
            }

            let method = readUInt16LE(bytes, at: cursor + 10)
            let crc = readUInt32LE(bytes, at: cursor + 16)
            let compressedSize = Int(readUInt32LE(bytes, at: cursor + 20))
            let uncompressedSize = Int(readUInt32LE(bytes, at: cursor + 24))
            let nameLength = Int(readUInt16LE(bytes, at: cursor + 28))
            let extraLength = Int(readUInt16LE(bytes, at: cursor + 30))
            let commentLength = Int(readUInt16LE(bytes, at: cursor + 32))
            let externalAttrs = readUInt32LE(bytes, at: cursor + 38)
            let localOffset = Int(readUInt32LE(bytes, at: cursor + 42))

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else {
                throw ShellError.unsupported("invalid zip entry name")
            }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self)

            let nextCursor = nameEnd + extraLength + commentLength
            guard nextCursor <= bytes.count else {
                throw ShellError.unsupported("invalid zip central entry")
            }

            let payload = try readLocalPayload(
                bytes: bytes,
                localOffset: localOffset,
                compressedSize: compressedSize
            )

            let data: Data
            switch method {
            case 0:
                data = payload
            case 8:
                data = try RawDeflateCodec.decompress(payload, expectedSize: uncompressedSize)
            default:
                throw ShellError.unsupported("unsupported zip compression method: \(method)")
            }

            guard data.count == uncompressedSize else {
                throw ShellError.unsupported("zip size mismatch for \(name)")
            }
            guard CRC32.checksum(data) == crc else {
                throw ShellError.unsupported("zip CRC mismatch for \(name)")
            }

            let isDirectory = name.hasSuffix("/") || (externalAttrs & 0x10) != 0
            let mode = Int((externalAttrs >> 16) & 0xffff)
            if isDirectory {
                let directoryName = name.hasSuffix("/") ? name : name + "/"
                entries.append(.directory(path: directoryName, mode: mode, modificationTime: 0))
            } else {
                entries.append(.file(path: name, data: data, mode: mode, modificationTime: 0))
            }

            cursor = nextCursor
        }

        return entries
    }

    private static func findEOCDOffset(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else {
            return nil
        }

        let minOffset = max(0, bytes.count - 66_000)
        var index = bytes.count - 22
        while index >= minOffset {
            if readUInt32LE(bytes, at: index) == 0x06054b50 {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func readLocalPayload(bytes: [UInt8], localOffset: Int, compressedSize: Int) throws -> Data {
        guard localOffset + 30 <= bytes.count else {
            throw ShellError.unsupported("invalid zip local header")
        }
        guard readUInt32LE(bytes, at: localOffset) == 0x04034b50 else {
            throw ShellError.unsupported("invalid zip local header")
        }

        let nameLength = Int(readUInt16LE(bytes, at: localOffset + 26))
        let extraLength = Int(readUInt16LE(bytes, at: localOffset + 28))
        let dataStart = localOffset + 30 + nameLength + extraLength
        let dataEnd = dataStart + compressedSize

        guard dataStart >= 0, dataEnd <= bytes.count, dataEnd >= dataStart else {
            throw ShellError.unsupported("invalid zip local payload")
        }

        return Data(bytes[dataStart..<dataEnd])
    }

    private static func normalizePathForEntry(_ entry: Entry) -> String {
        let cleaned = cleanEntryPath(entry.path)
        if case .directory = entry.kind, !cleaned.hasSuffix("/") {
            return cleaned + "/"
        }
        return cleaned
    }

    private static func externalAttributes(for entry: Entry) -> UInt32 {
        let mode = UInt32(entry.mode & 0xffff) << 16
        if case .directory = entry.kind {
            return mode | 0x10
        }
        return mode
    }

    private static func dosTimestamp(from unixTime: Int) -> (time: UInt16, date: UInt16) {
        let date = Date(timeIntervalSince1970: TimeInterval(unixTime))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)

        let year = max(1980, min(2107, components.year ?? 1980))
        let month = max(1, min(12, components.month ?? 1))
        let day = max(1, min(31, components.day ?? 1))
        let hour = max(0, min(23, components.hour ?? 0))
        let minute = max(0, min(59, components.minute ?? 0))
        let second = max(0, min(59, components.second ?? 0))

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { rawBuffer in
            data.append(contentsOf: rawBuffer)
        }
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

private enum RawDeflateCodec {
    static func compress(_ input: Data) throws -> Data {
        #if canImport(zlib)
        var stream = z_stream()
        let initResult = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw ShellError.unsupported("zip compression initialization failed")
        }
        defer { deflateEnd(&stream) }

        var output = Data()
        try input.withUnsafeBytes { rawInput in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(rawInput.count)

            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: 16_384)
                status = buffer.withUnsafeMutableBytes { rawBuffer in
                    stream.next_out = rawBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(rawBuffer.count)
                    return deflate(&stream, Z_FINISH)
                }

                let produced = buffer.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw ShellError.unsupported("zip compression failed")
            }
        }
        return output
        #else
        throw ShellError.unsupported("zip compression is unavailable on this platform")
        #endif
    }

    static func decompress(_ input: Data, expectedSize: Int) throws -> Data {
        #if canImport(zlib)
        var stream = z_stream()
        let initResult = inflateInit2_(
            &stream,
            -MAX_WBITS,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            throw ShellError.unsupported("zip decompression initialization failed")
        }
        defer { inflateEnd(&stream) }

        var output = Data()
        try input.withUnsafeBytes { rawInput in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: rawInput.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(rawInput.count)

            var status: Int32 = Z_OK
            repeat {
                var buffer = [UInt8](repeating: 0, count: max(16_384, min(1_048_576, expectedSize + 64)))
                status = buffer.withUnsafeMutableBytes { rawBuffer in
                    stream.next_out = rawBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(rawBuffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let produced = buffer.count - Int(stream.avail_out)
                if produced > 0 {
                    output.append(contentsOf: buffer[0..<produced])
                }

                if status == Z_BUF_ERROR, stream.avail_in == 0 {
                    break
                }
            } while status == Z_OK

            guard status == Z_STREAM_END else {
                throw ShellError.unsupported("zip decompression failed")
            }
        }

        return output
        #else
        throw ShellError.unsupported("zip decompression is unavailable on this platform")
        #endif
    }
}

private enum TarCodec {
    struct Entry {
        enum Kind {
            case file(Data)
            case directory
        }

        let path: String
        let kind: Kind
        let mode: Int
        let modificationTime: Int

        static func file(path: String, data: Data, mode: Int, modificationTime: Int) -> Entry {
            Entry(path: path, kind: .file(data), mode: mode, modificationTime: modificationTime)
        }

        static func directory(path: String, mode: Int, modificationTime: Int) -> Entry {
            Entry(path: path, kind: .directory, mode: mode, modificationTime: modificationTime)
        }
    }

    static func cleanArchivePath(_ path: String) -> String {
        var output = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if output.hasPrefix("./") {
            output.removeFirst(2)
        }
        if output.isEmpty {
            output = "root"
        }
        return output
    }

    static func encode(entries: [Entry]) throws -> Data {
        var archive = Data()
        for entry in entries {
            try appendEntry(entry, to: &archive)
        }
        archive.append(Data(repeating: 0x00, count: 1024))
        return archive
    }

    static func decode(data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        var offset = 0
        var entries: [Entry] = []

        while offset + 512 <= bytes.count {
            let block = Array(bytes[offset..<(offset + 512)])
            if block.allSatisfy({ $0 == 0 }) {
                break
            }

            let name = parseName(from: block)
            let mode = parseOctal(from: block, offset: 100, length: 8)
            let size = parseOctal(from: block, offset: 124, length: 12)
            let typeFlag = block[156]

            let payloadStart = offset + 512
            let payloadLength = Int(size)
            let paddedLength = ((payloadLength + 511) / 512) * 512
            guard payloadStart + paddedLength <= bytes.count else {
                throw ShellError.unsupported("invalid tar stream")
            }

            if typeFlag == 53 { // '5'
                let normalizedName = name.hasSuffix("/") ? name : name + "/"
                entries.append(.directory(path: normalizedName, mode: mode, modificationTime: 0))
            } else {
                let payloadEnd = payloadStart + payloadLength
                let payload = Data(bytes[payloadStart..<payloadEnd])
                entries.append(.file(path: name, data: payload, mode: mode, modificationTime: 0))
            }

            offset = payloadStart + paddedLength
        }

        return entries
    }

    private static func appendEntry(_ entry: Entry, to archive: inout Data) throws {
        let path = cleanArchivePath(entry.path)
        let (nameField, prefixField) = try splitPath(path)

        var header = [UInt8](repeating: 0x00, count: 512)

        try writeString(nameField, to: &header, offset: 0, length: 100)
        try writeOctal(entry.mode & 0o7777, to: &header, offset: 100, length: 8)
        try writeOctal(0, to: &header, offset: 108, length: 8) // uid
        try writeOctal(0, to: &header, offset: 116, length: 8) // gid

        let payloadSize: Int
        let typeFlag: UInt8
        let payload: Data
        switch entry.kind {
        case let .file(data):
            payloadSize = data.count
            typeFlag = 48 // '0'
            payload = data
        case .directory:
            payloadSize = 0
            typeFlag = 53 // '5'
            payload = Data()
        }

        try writeOctal(payloadSize, to: &header, offset: 124, length: 12)
        try writeOctal(entry.modificationTime, to: &header, offset: 136, length: 12)

        for index in 148..<156 {
            header[index] = 0x20
        }

        header[156] = typeFlag
        try writeString("ustar", to: &header, offset: 257, length: 6)
        try writeString("00", to: &header, offset: 263, length: 2)
        try writeString("user", to: &header, offset: 265, length: 32)
        try writeString("group", to: &header, offset: 297, length: 32)
        if let prefixField {
            try writeString(prefixField, to: &header, offset: 345, length: 155)
        }

        let checksum = header.reduce(0) { $0 + Int($1) }
        try writeChecksum(checksum, to: &header)

        archive.append(contentsOf: header)
        archive.append(payload)

        if payloadSize % 512 != 0 {
            archive.append(Data(repeating: 0x00, count: 512 - (payloadSize % 512)))
        }
    }

    private static func parseName(from header: [UInt8]) -> String {
        let name = parseString(from: header, offset: 0, length: 100)
        let prefix = parseString(from: header, offset: 345, length: 155)
        if prefix.isEmpty {
            return name
        }
        return prefix + "/" + name
    }

    private static func parseString(from header: [UInt8], offset: Int, length: Int) -> String {
        let slice = header[offset..<(offset + length)]
        let bytes = Array(slice.prefix { $0 != 0x00 })
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func parseOctal(from header: [UInt8], offset: Int, length: Int) -> Int {
        let raw = parseString(from: header, offset: offset, length: length)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return 0
        }
        return Int(trimmed, radix: 8) ?? 0
    }

    private static func splitPath(_ path: String) throws -> (name: String, prefix: String?) {
        if path.utf8.count <= 100 {
            return (path, nil)
        }

        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            throw ShellError.unsupported("tar path is too long: \(path)")
        }

        for split in stride(from: parts.count - 1, through: 1, by: -1) {
            let prefix = parts[..<split].joined(separator: "/")
            let name = parts[split...].joined(separator: "/")
            if prefix.utf8.count <= 155, name.utf8.count <= 100 {
                return (name, prefix)
            }
        }

        throw ShellError.unsupported("tar path is too long: \(path)")
    }

    private static func writeString(
        _ value: String,
        to header: inout [UInt8],
        offset: Int,
        length: Int
    ) throws {
        let bytes = [UInt8](value.utf8)
        guard bytes.count <= length else {
            throw ShellError.unsupported("tar header field overflow")
        }
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
    }

    private static func writeOctal(
        _ value: Int,
        to header: inout [UInt8],
        offset: Int,
        length: Int
    ) throws {
        guard value >= 0 else {
            throw ShellError.unsupported("negative tar numeric field")
        }
        let maxDigits = max(1, length - 1)
        let encoded = String(value, radix: 8)
        guard encoded.utf8.count <= maxDigits else {
            throw ShellError.unsupported("tar numeric field overflow")
        }

        let padded = String(repeating: "0", count: maxDigits - encoded.utf8.count) + encoded
        let bytes = [UInt8](padded.utf8)
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
        header[offset + maxDigits] = 0x00
    }

    private static func writeChecksum(_ value: Int, to header: inout [UInt8]) throws {
        let encoded = String(value, radix: 8)
        guard encoded.utf8.count <= 6 else {
            throw ShellError.unsupported("tar checksum overflow")
        }

        let padded = String(repeating: "0", count: 6 - encoded.utf8.count) + encoded
        let bytes = [UInt8](padded.utf8)
        for (index, byte) in bytes.enumerated() {
            header[148 + index] = byte
        }
        header[154] = 0x00
        header[155] = 0x20
    }
}
