import Foundation
import Bash

#if canImport(JavaScriptCore)
import JavaScriptCore
#endif

public enum PyodideLoaderSource: Sendable {
    case inline(String)
    case file(URL)
    case remote(URL)
}

public struct PyodideConfiguration: Sendable {
    public var loaderSource: PyodideLoaderSource
    public var indexURL: URL
    public var networkTimeout: TimeInterval

    public init(
        loaderSource: PyodideLoaderSource,
        indexURL: URL,
        networkTimeout: TimeInterval = 60
    ) {
        self.loaderSource = loaderSource
        self.indexURL = indexURL
        self.networkTimeout = networkTimeout
    }

    public static let `default`: PyodideConfiguration = {
        if let bundledLoaderURL = Bundle.module.url(
            forResource: "pyodide",
            withExtension: "js",
            subdirectory: "pyodide"
        ) ?? Bundle.module.url(
            forResource: "pyodide",
            withExtension: "js"
        ) {
            return PyodideConfiguration(
                loaderSource: .file(bundledLoaderURL),
                indexURL: bundledLoaderURL.deletingLastPathComponent(),
                networkTimeout: 60
            )
        }

        return PyodideConfiguration(
            loaderSource: .inline(
                "function loadPyodide(){ throw new Error('Bundled pyodide.js resource not found in BashPython resources'); }"
            ),
            indexURL: URL(fileURLWithPath: "/", isDirectory: true),
            networkTimeout: 60
        )
    }()
}

private enum PyodideRuntimeError: LocalizedError {
    case unavailable(String)
    case initializationFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            return message
        case let .initializationFailed(message):
            return message
        case let .executionFailed(message):
            return message
        }
    }
}

#if canImport(JavaScriptCore)
public actor PyodideRuntime: PythonRuntime {
    private let configuration: PyodideConfiguration
    private let filesystemBridge = PyodideFilesystemBridge()
    private let fetchBridge = PyodideFetchBridge()

    private var context: JSContext?
    private var didAttemptInitialization = false
    private var initializationError: String?

    public init(configuration: PyodideConfiguration = .default) {
        self.configuration = configuration
        fetchBridge.timeout = configuration.networkTimeout
    }

    public func execute(
        request: PythonExecutionRequest,
        filesystem: any ShellFilesystem
    ) async -> PythonExecutionResult {
        do {
            let context = try await ensureInitialized()

            filesystemBridge.setContext(
                filesystem: filesystem,
                currentDirectory: request.currentDirectory
            )
            defer {
                filesystemBridge.clearContext()
            }

            let payload: [String: Any] = [
                "mode": request.mode.rawValue,
                "source": request.source,
                "scriptPath": request.scriptPath ?? "",
                "arguments": request.arguments,
                "cwd": request.currentDirectory,
                "env": request.environment,
                "stdin": request.stdin,
            ]

            let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let payloadJSON = String(decoding: payloadData, as: UTF8.self)
            let expression = "__bashswift_run_python(\(jsStringLiteral(payloadJSON)))"
            let resultJSON = try await evaluatePromiseString(
                context: context,
                expression: expression
            )

            let decoded = try decodeExecutionResult(from: resultJSON)
            return decoded
        } catch {
            return PythonExecutionResult(
                stdout: "",
                stderr: "python3: \(error.localizedDescription)\n",
                exitCode: 1
            )
        }
    }

    private func ensureInitialized() async throws -> JSContext {
        if let context {
            return context
        }

        if didAttemptInitialization, let initializationError {
            throw PyodideRuntimeError.initializationFailed(initializationError)
        }

        didAttemptInitialization = true

        guard let context = JSContext() else {
            let message = "failed to create JavaScriptCore context"
            initializationError = message
            throw PyodideRuntimeError.initializationFailed(message)
        }

        context.exceptionHandler = { _, exception in
            _ = exception
        }

        let fsBridge = filesystemBridge
        let fetchBridge = fetchBridge

        let fsBlock: @convention(block) (NSString) -> NSString = { requestJSON in
            fsBridge.handle(requestJSON: requestJSON as String) as NSString
        }
        context.setObject(fsBlock, forKeyedSubscript: "__bashswift_fs_bridge" as NSString)

        let fetchBlock: @convention(block) (NSString) -> NSString = { url in
            fetchBridge.fetchSync(url: url as String) as NSString
        }
        context.setObject(fetchBlock, forKeyedSubscript: "__bashswift_fetch_sync" as NSString)

        context.evaluateScript(PyodideScripts.environmentScript)

        do {
            let loaderScript = try await loadLoaderScript()
            context.evaluateScript(loaderScript)

            let loadExpression = """
            (async function() {
                const pyodide = await loadPyodide({ indexURL: \(jsStringLiteral(configuration.indexURL.absoluteString)) });
                globalThis.__bashswift_pyodide = pyodide;
                return "ok";
            })()
            """
            _ = try await evaluatePromiseString(context: context, expression: loadExpression)

            context.evaluateScript(PyodideScripts.hostFilesystemAndRunnerScript)

            let initializeExpression = """
            (async function() {
                await __bashswift_initialize_runtime();
                return "ok";
            })()
            """
            _ = try await evaluatePromiseString(context: context, expression: initializeExpression)
        } catch {
            let message = error.localizedDescription
            initializationError = message
            throw PyodideRuntimeError.initializationFailed(message)
        }

        self.context = context
        return context
    }

    private func decodeExecutionResult(from resultJSON: String) throws -> PythonExecutionResult {
        guard let data = resultJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PyodideRuntimeError.executionFailed("invalid Python runtime response")
        }

        let stdout = object["stdout"] as? String ?? ""
        let stderr = object["stderr"] as? String ?? ""
        let exitCode = (object["exitCode"] as? NSNumber)?.int32Value ?? 1

        return PythonExecutionResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }

    private func loadLoaderScript() async throws -> String {
        switch configuration.loaderSource {
        case let .inline(script):
            return script
        case let .file(url):
            let data = try Data(contentsOf: url)
            guard let script = String(data: data, encoding: .utf8) else {
                throw PyodideRuntimeError.initializationFailed("failed to decode loader script")
            }
            return script
        case let .remote(url):
            var request = URLRequest(url: url)
            request.timeoutInterval = configuration.networkTimeout
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let script = String(data: data, encoding: .utf8) else {
                throw PyodideRuntimeError.initializationFailed("failed to decode remote loader script")
            }
            return script
        }
    }

    private func evaluatePromiseString(
        context: JSContext,
        expression: String
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            let resolveBlock: @convention(block) (JSValue?) -> Void = { value in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                let stringValue = value?.toString() ?? ""
                continuation.resume(returning: stringValue)
            }

            let rejectBlock: @convention(block) (NSString?) -> Void = { message in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                let text = (message as String?) ?? "unknown JavaScript error"
                continuation.resume(throwing: PyodideRuntimeError.executionFailed(text))
            }

            context.setObject(resolveBlock, forKeyedSubscript: "__bashswift_resolve" as NSString)
            context.setObject(rejectBlock, forKeyedSubscript: "__bashswift_reject" as NSString)

            let wrappedScript = """
            (async function() {
                try {
                    const __bashswift_result = await (\(expression));
                    if (typeof __bashswift_result === "string") {
                        __bashswift_resolve(__bashswift_result);
                    } else {
                        __bashswift_resolve(JSON.stringify(__bashswift_result));
                    }
                } catch (__bashswift_error) {
                    __bashswift_reject(String(__bashswift_error));
                }
            })();
            """

            context.evaluateScript(wrappedScript)

            if let exception = context.exception?.toString(), !exception.isEmpty {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                context.exception = nil
                continuation.resume(throwing: PyodideRuntimeError.executionFailed(exception))
            }
        }
    }

    private func jsStringLiteral(_ value: String) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let jsonArray = String(decoding: encoded, as: UTF8.self)
        return String(jsonArray.dropFirst().dropLast())
    }
}
#else
public actor PyodideRuntime: PythonRuntime {
    private let configuration: PyodideConfiguration

    public init(configuration: PyodideConfiguration = .default) {
        self.configuration = configuration
    }

    public func execute(
        request: PythonExecutionRequest,
        filesystem: any ShellFilesystem
    ) async -> PythonExecutionResult {
        _ = configuration
        _ = request
        _ = filesystem
        return PythonExecutionResult(
            stdout: "",
            stderr: "python3: JavaScriptCore is unavailable on this platform\n",
            exitCode: 1
        )
    }
}
#endif

private final class PyodideFilesystemBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var filesystem: (any ShellFilesystem)?
    private var currentDirectory: String = "/"

    func setContext(filesystem: any ShellFilesystem, currentDirectory: String) {
        lock.lock()
        defer { lock.unlock() }
        self.filesystem = filesystem
        self.currentDirectory = currentDirectory
    }

    func clearContext() {
        lock.lock()
        defer { lock.unlock() }
        filesystem = nil
    }

    func handle(requestJSON: String) -> String {
        guard let data = requestJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String
        else {
            return response(error: "invalid bridge request")
        }

        do {
            switch op {
            case "readFile":
                let path = try resolvedPath(from: object)
                let data = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.readFile(path: path)
                }
                return response(success: ["dataBase64": data.base64EncodedString()])

            case "writeFile":
                let path = try resolvedPath(from: object)
                let decoded = Data(base64Encoded: object["dataBase64"] as? String ?? "") ?? Data()
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.writeFile(path: path, data: decoded, append: false)
                }
                return response(success: [:])

            case "appendFile":
                let path = try resolvedPath(from: object)
                let decoded = Data(base64Encoded: object["dataBase64"] as? String ?? "") ?? Data()
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.writeFile(path: path, data: decoded, append: true)
                }
                return response(success: [:])

            case "stat", "lstat":
                let path = try resolvedPath(from: object)
                let info = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.stat(path: path)
                }
                let mtime = info.modificationDate?.timeIntervalSince1970 ?? 0
                return response(success: [
                    "stat": [
                        "isFile": !info.isDirectory,
                        "isDirectory": info.isDirectory,
                        "isSymbolicLink": info.isSymbolicLink,
                        "mode": info.permissions,
                        "size": info.size,
                        "mtime": mtime,
                    ]
                ])

            case "readdir":
                let path = try resolvedPath(from: object)
                let entries = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.listDirectory(path: path).map(\ .name).sorted()
                }
                return response(success: ["entries": entries])

            case "mkdir":
                let path = try resolvedPath(from: object)
                let recursive = object["recursive"] as? Bool ?? false
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.createDirectory(path: path, recursive: recursive)
                }
                return response(success: [:])

            case "rm":
                let path = try resolvedPath(from: object)
                let recursive = object["recursive"] as? Bool ?? false
                let force = object["force"] as? Bool ?? false

                let exists = try runBlocking { () -> Bool in
                    guard let filesystem = self.snapshot().filesystem else {
                        return false
                    }
                    return await filesystem.exists(path: path)
                }

                if !exists {
                    return force ? response(success: [:]) : response(error: "No such file or directory")
                }

                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.remove(path: path, recursive: recursive)
                }
                return response(success: [:])

            case "exists":
                let path = try resolvedPath(from: object)
                let exists = try runBlocking { () -> Bool in
                    guard let filesystem = self.snapshot().filesystem else {
                        return false
                    }
                    return await filesystem.exists(path: path)
                }
                return response(success: ["exists": exists])

            case "symlink":
                let path = try resolvedPath(from: object)
                let target = object["target"] as? String ?? ""
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.createSymlink(path: path, target: target)
                }
                return response(success: [:])

            case "readlink":
                let path = try resolvedPath(from: object)
                let target = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.readSymlink(path: path)
                }
                return response(success: ["target": target])

            case "chmod":
                let path = try resolvedPath(from: object)
                let mode = object["mode"] as? Int ?? 0o644
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.setPermissions(path: path, permissions: mode)
                }
                return response(success: [:])

            case "realpath":
                let path = try resolvedPath(from: object)
                let value = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw PyodideRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.resolveRealPath(path: path)
                }
                return response(success: ["path": value])

            default:
                return response(error: "unsupported operation: \(op)")
            }
        } catch {
            return response(error: String(describing: error))
        }
    }

    private func snapshot() -> (filesystem: (any ShellFilesystem)?, currentDirectory: String) {
        lock.lock()
        defer { lock.unlock() }
        return (filesystem, currentDirectory)
    }

    private func resolvedPath(from payload: [String: Any]) throws -> String {
        guard var path = payload["path"] as? String else {
            throw PyodideRuntimeError.executionFailed("filesystem path is required")
        }

        if path.hasPrefix("/host/") {
            path.removeFirst(5)
        } else if path == "/host" {
            path = "/"
        }

        let snapshot = snapshot()
        return normalize(path: path, currentDirectory: snapshot.currentDirectory)
    }

    private func normalize(path: String, currentDirectory: String) -> String {
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

    private func splitComponents(_ absolutePath: String) -> [String] {
        absolutePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    private func runBlocking<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingResultBox<T>()

        Task.detached {
            do {
                let value = try await operation()
                box.set(.success(value))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        semaphore.wait()
        switch box.get() {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        case .none:
            throw PyodideRuntimeError.executionFailed("filesystem operation did not produce a result")
        }
    }

    private func response(success: [String: Any]) -> String {
        var payload: [String: Any] = ["ok": true]
        payload.merge(success) { _, rhs in rhs }
        return jsonString(payload)
    }

    private func response(error: String) -> String {
        jsonString(["ok": false, "error": error])
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private final class BlockingResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<T, Error>?

    func set(_ value: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        storage = value
    }

    func get() -> Result<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class PyodideFetchBridge: @unchecked Sendable {
    var timeout: TimeInterval = 60

    func fetchSync(url: String) -> String {
        guard let resolvedURL = URL(string: url) else {
            return jsonString([
                "ok": false,
                "error": "invalid url: \(url)",
            ])
        }

        do {
            var request = URLRequest(url: resolvedURL)
            request.timeoutInterval = timeout
            let body = try Data(contentsOf: request.url ?? resolvedURL)
            return jsonString([
                "ok": true,
                "status": 200,
                "statusText": "ok",
                "url": resolvedURL.absoluteString,
                "headers": [:],
                "dataBase64": body.base64EncodedString(),
            ])
        } catch {
            return jsonString([
                "ok": false,
                "error": error.localizedDescription,
            ])
        }
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

private enum PyodideScripts {
    static let environmentScript = #"""
    globalThis.self = globalThis;
    globalThis.window = globalThis;

    function __bashswift_b64_to_bytes(base64) {
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      const cleaned = String(base64 || '').replace(/=+$/, '');
      const bytes = [];
      let bits = 0;
      let bitCount = 0;
      let acc = 0;
      let accumulator = { value: 0, count: 0 };

      for (let i = 0; i < cleaned.length; i++) {
        const index = alphabet.indexOf(cleaned[i]);
        if (index === -1) continue;

        accumulator.value = (accumulator.value << 6) | index;
        accumulator.count += 6;

        while (accumulator.count >= 8) {
          accumulator.count -= 8;
          bytes.push((accumulator.value >> accumulator.count) & 0xFF);
        }
      }

      return new Uint8Array(bytes);
    }

    function __bashswift_bytes_to_b64(bytes) {
      const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      let output = '';
      for (let i = 0; i < bytes.length; i += 3) {
        const a = bytes[i];
        const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
        const c = i + 2 < bytes.length ? bytes[i + 2] : 0;

        const triple = (a << 16) | (b << 8) | c;
        output += alphabet[(triple >> 18) & 0x3F];
        output += alphabet[(triple >> 12) & 0x3F];
        output += i + 1 < bytes.length ? alphabet[(triple >> 6) & 0x3F] : '=';
        output += i + 2 < bytes.length ? alphabet[triple & 0x3F] : '=';
      }
      return output;
    }

    function __bashswift_decode_utf8(bytes) {
      if (typeof TextDecoder !== 'undefined') {
        return new TextDecoder().decode(bytes);
      }

      let output = '';
      for (let i = 0; i < bytes.length; i++) {
        output += String.fromCharCode(bytes[i]);
      }
      return output;
    }

    globalThis.__bashswift_b64_to_bytes = __bashswift_b64_to_bytes;
    globalThis.__bashswift_bytes_to_b64 = __bashswift_bytes_to_b64;

    if (typeof fetch !== 'function') {
      globalThis.fetch = function(input) {
        const url = typeof input === 'string' ? input : (input && input.url ? input.url : String(input));
        const raw = __bashswift_fetch_sync(url);
        const payload = JSON.parse(raw || '{}');

        const bytes = __bashswift_b64_to_bytes(payload.dataBase64 || '');
        const headersMap = payload.headers || {};
        const headers = {
          get(name) {
            const key = Object.keys(headersMap).find((item) => item.toLowerCase() === String(name).toLowerCase());
            return key ? headersMap[key] : null;
          }
        };

        return Promise.resolve({
          ok: !!payload.ok,
          status: payload.status || 0,
          statusText: payload.statusText || '',
          url: payload.url || url,
          headers,
          arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
          text: async () => __bashswift_decode_utf8(bytes),
          json: async () => JSON.parse(__bashswift_decode_utf8(bytes))
        });
      };
    }
    """#

    static let hostFilesystemAndRunnerScript = #"""
    function __bashswift_fs_call(op, payload) {
      const request = Object.assign({ op }, payload || {});
      const rawResponse = __bashswift_fs_bridge(JSON.stringify(request));
      const response = JSON.parse(rawResponse || '{}');
      if (!response.ok) {
        throw new Error(response.error || 'filesystem bridge error');
      }
      return response;
    }

    function __bashswift_create_hostfs(FS, PATH) {
      const ERRNO = {
        EPERM: 63,
        ENOENT: 44,
        EIO: 29,
        EACCES: 2,
        EEXIST: 20,
        ENOTDIR: 54,
        EISDIR: 31,
        EINVAL: 28,
        ENOTEMPTY: 55,
      };

      function toErrno(error) {
        const text = String(error || '').toLowerCase();
        if (text.includes('no such file')) return ERRNO.ENOENT;
        if (text.includes('not a directory')) return ERRNO.ENOTDIR;
        if (text.includes('is a directory')) return ERRNO.EISDIR;
        if (text.includes('already exists')) return ERRNO.EEXIST;
        if (text.includes('permission')) return ERRNO.EACCES;
        if (text.includes('not empty')) return ERRNO.ENOTEMPTY;
        return ERRNO.EIO;
      }

      function wrap(operation) {
        try {
          return operation();
        } catch (error) {
          throw new FS.ErrnoError(toErrno(error));
        }
      }

      function realPath(node) {
        const parts = [];
        while (node.parent !== node) {
          parts.push(node.name);
          node = node.parent;
        }
        parts.push(node.mount.opts.root);
        parts.reverse();
        return PATH.join(...parts);
      }

      function modeFromPath(path) {
        return wrap(() => {
          const stat = __bashswift_fs_call('stat', { path }).stat;
          let mode = stat.mode & 0o777;
          if (stat.isDirectory) {
            mode |= 0o40000;
          } else if (stat.isSymbolicLink) {
            mode |= 0o120000;
          } else {
            mode |= 0o100000;
          }
          return mode;
        });
      }

      const HOSTFS = {
        mount(_mount) {
          return HOSTFS.createNode(null, '/', 0o40755, 0);
        },

        createNode(parent, name, mode, dev) {
          if (!FS.isDir(mode) && !FS.isFile(mode) && !FS.isLink(mode)) {
            throw new FS.ErrnoError(ERRNO.EINVAL);
          }
          const node = FS.createNode(parent, name, mode, dev);
          node.node_ops = HOSTFS.node_ops;
          node.stream_ops = HOSTFS.stream_ops;
          return node;
        },

        node_ops: {
          getattr(node) {
            return wrap(() => {
              const stat = __bashswift_fs_call('stat', { path: realPath(node) }).stat;
              let mode = stat.mode & 0o777;
              if (stat.isDirectory) {
                mode |= 0o40000;
              } else if (stat.isSymbolicLink) {
                mode |= 0o120000;
              } else {
                mode |= 0o100000;
              }
              return {
                dev: 1,
                ino: node.id,
                mode,
                nlink: 1,
                uid: 0,
                gid: 0,
                rdev: 0,
                size: stat.size,
                atime: new Date(stat.mtime * 1000),
                mtime: new Date(stat.mtime * 1000),
                ctime: new Date(stat.mtime * 1000),
                blksize: 4096,
                blocks: Math.ceil(stat.size / 512),
              };
            });
          },

          setattr(node, attr) {
            const path = realPath(node);
            if (typeof attr.mode === 'number') {
              wrap(() => __bashswift_fs_call('chmod', { path, mode: attr.mode }));
              node.mode = attr.mode;
            }
            if (typeof attr.size === 'number') {
              wrap(() => {
                const content = __bashswift_b64_to_bytes(__bashswift_fs_call('readFile', { path }).dataBase64 || '');
                const resized = content.slice(0, attr.size);
                __bashswift_fs_call('writeFile', {
                  path,
                  dataBase64: __bashswift_bytes_to_b64(resized),
                });
              });
            }
          },

          lookup(parent, name) {
            const path = PATH.join2(realPath(parent), name);
            return HOSTFS.createNode(parent, name, modeFromPath(path));
          },

          mknod(parent, name, mode, dev) {
            const node = HOSTFS.createNode(parent, name, mode, dev);
            const path = realPath(node);
            wrap(() => {
              if (FS.isDir(node.mode)) {
                __bashswift_fs_call('mkdir', { path, recursive: false });
              } else {
                __bashswift_fs_call('writeFile', { path, dataBase64: '' });
              }
            });
            return node;
          },

          rename(oldNode, newDir, newName) {
            wrap(() => {
              const oldPath = realPath(oldNode);
              const newPath = PATH.join2(realPath(newDir), newName);
              const data = __bashswift_fs_call('readFile', { path: oldPath }).dataBase64 || '';
              __bashswift_fs_call('writeFile', { path: newPath, dataBase64: data });
              __bashswift_fs_call('rm', { path: oldPath, recursive: false, force: false });
              oldNode.name = newName;
            });
          },

          unlink(parent, name) {
            const path = PATH.join2(realPath(parent), name);
            wrap(() => __bashswift_fs_call('rm', { path, recursive: false, force: false }));
          },

          rmdir(parent, name) {
            const path = PATH.join2(realPath(parent), name);
            wrap(() => __bashswift_fs_call('rm', { path, recursive: false, force: false }));
          },

          readdir(node) {
            return wrap(() => __bashswift_fs_call('readdir', { path: realPath(node) }).entries || []);
          },

          symlink(parent, newName, oldPath) {
            const path = PATH.join2(realPath(parent), newName);
            wrap(() => __bashswift_fs_call('symlink', { path, target: oldPath }));
          },

          readlink(node) {
            return wrap(() => __bashswift_fs_call('readlink', { path: realPath(node) }).target || '');
          }
        },

        stream_ops: {
          open(stream) {
            if (FS.isDir(stream.node.mode)) {
              return;
            }

            const path = realPath(stream.node);
            const flags = stream.flags;
            const O_WRONLY = 1;
            const O_RDWR = 2;
            const O_CREAT = 64;
            const O_TRUNC = 512;
            const O_APPEND = 1024;

            const accessMode = flags & 3;
            const canWrite = accessMode === O_WRONLY || accessMode === O_RDWR;
            const truncate = (flags & O_TRUNC) !== 0;
            const create = (flags & O_CREAT) !== 0;
            const append = (flags & O_APPEND) !== 0;

            let content;
            if (truncate && canWrite) {
              content = new Uint8Array(0);
            } else {
              try {
                const encoded = __bashswift_fs_call('readFile', { path }).dataBase64 || '';
                content = __bashswift_b64_to_bytes(encoded);
              } catch (error) {
                if (create && canWrite) {
                  content = new Uint8Array(0);
                } else {
                  throw new FS.ErrnoError(ERRNO.ENOENT);
                }
              }
            }

            stream.hostPath = path;
            stream.hostContent = content;
            stream.hostModified = truncate && canWrite;
            if (append) {
              stream.position = content.length;
            }
          },

          close(stream) {
            if (stream.hostModified && stream.hostPath && stream.hostContent) {
              wrap(() => __bashswift_fs_call('writeFile', {
                path: stream.hostPath,
                dataBase64: __bashswift_bytes_to_b64(stream.hostContent),
              }));
            }
            delete stream.hostPath;
            delete stream.hostContent;
            delete stream.hostModified;
          },

          read(stream, buffer, offset, length, position) {
            const content = stream.hostContent || new Uint8Array(0);
            if (position >= content.length) {
              return 0;
            }
            const count = Math.min(length, content.length - position);
            buffer.set(content.subarray(position, position + count), offset);
            return count;
          },

          write(stream, buffer, offset, length, position) {
            let content = stream.hostContent || new Uint8Array(0);
            const nextLength = Math.max(content.length, position + length);
            if (nextLength > content.length) {
              const expanded = new Uint8Array(nextLength);
              expanded.set(content);
              content = expanded;
              stream.hostContent = content;
            }

            content.set(buffer.subarray(offset, offset + length), position);
            stream.hostModified = true;
            return length;
          },

          llseek(stream, offset, whence) {
            const SEEK_CUR = 1;
            const SEEK_END = 2;
            let position = offset;
            if (whence === SEEK_CUR) {
              position += stream.position;
            } else if (whence === SEEK_END) {
              const content = stream.hostContent || new Uint8Array(0);
              position += content.length;
            }
            if (position < 0) {
              throw new FS.ErrnoError(ERRNO.EINVAL);
            }
            return position;
          }
        }
      };

      return HOSTFS;
    }

    async function __bashswift_initialize_runtime() {
      const pyodide = globalThis.__bashswift_pyodide;
      if (!pyodide) {
        throw new Error('Pyodide is not initialized');
      }

      const FS = pyodide.FS;
      const PATH = pyodide.PATH;

      if (!globalThis.__bashswift_hostfs) {
        globalThis.__bashswift_hostfs = __bashswift_create_hostfs(FS, PATH);
      }

      try {
        pyodide.runPython(`import os\nos.chdir('/')`);
      } catch (_error) {
      }

      try {
        FS.mkdir('/host');
      } catch (_error) {
      }

      try {
        FS.unmount('/host');
      } catch (_error) {
      }

      FS.mount(globalThis.__bashswift_hostfs, { root: '/' }, '/host');
    }

    async function __bashswift_run_python(payloadJSON) {
      const pyodide = globalThis.__bashswift_pyodide;
      if (!pyodide) {
        throw new Error('Pyodide is not initialized');
      }

      const payload = JSON.parse(payloadJSON || '{}');
      await __bashswift_initialize_runtime();

      pyodide.globals.set('__bashswift_payload_json', JSON.stringify(payload));

      await pyodide.runPythonAsync(`
import builtins
import io
import json
import os
import runpy
import sys
import traceback

_payload = json.loads(__bashswift_payload_json)

if _payload.get('env'):
    for _key, _value in _payload['env'].items():
        os.environ[str(_key)] = str(_value)

if not hasattr(builtins, '__bashswift_open_original'):
    builtins.__bashswift_open_original = builtins.open

if not hasattr(os, '__bashswift_getcwd_original'):
    os.__bashswift_getcwd_original = os.getcwd

if not hasattr(os, '__bashswift_chdir_original'):
    os.__bashswift_chdir_original = os.chdir

if not hasattr(os, '__bashswift_listdir_original'):
    os.__bashswift_listdir_original = os.listdir

if not hasattr(os.path, '__bashswift_exists_original'):
    os.path.__bashswift_exists_original = os.path.exists

if not hasattr(os.path, '__bashswift_isfile_original'):
    os.path.__bashswift_isfile_original = os.path.isfile

if not hasattr(os.path, '__bashswift_isdir_original'):
    os.path.__bashswift_isdir_original = os.path.isdir

if not hasattr(os, '__bashswift_mkdir_original'):
    os.__bashswift_mkdir_original = os.mkdir

if not hasattr(os, '__bashswift_makedirs_original'):
    os.__bashswift_makedirs_original = os.makedirs

if not hasattr(os, '__bashswift_remove_original'):
    os.__bashswift_remove_original = os.remove

if not hasattr(os, '__bashswift_rmdir_original'):
    os.__bashswift_rmdir_original = os.rmdir

if not hasattr(os, '__bashswift_stat_original'):
    os.__bashswift_stat_original = os.stat


def __bashswift_should_redirect(path):
    return isinstance(path, str) and path.startswith('/') and not path.startswith('/host') and not path.startswith('/lib') and not path.startswith('/proc')


def __bashswift_redirect(path):
    if __bashswift_should_redirect(path):
        return '/host' + path
    return path


def __bashswift_open(path, mode='r', *args, **kwargs):
    return builtins.__bashswift_open_original(__bashswift_redirect(path), mode, *args, **kwargs)


builtins.open = __bashswift_open


def __bashswift_getcwd():
    _cwd = os.__bashswift_getcwd_original()
    if _cwd.startswith('/host'):
        return _cwd[5:] or '/'
    return _cwd


os.getcwd = __bashswift_getcwd


def __bashswift_chdir(path):
    return os.__bashswift_chdir_original(__bashswift_redirect(path))


os.chdir = __bashswift_chdir


def __bashswift_listdir(path='.'):
    return os.__bashswift_listdir_original(__bashswift_redirect(path))


os.listdir = __bashswift_listdir


def __bashswift_exists(path):
    return os.path.__bashswift_exists_original(__bashswift_redirect(path))


os.path.exists = __bashswift_exists


def __bashswift_isfile(path):
    return os.path.__bashswift_isfile_original(__bashswift_redirect(path))


os.path.isfile = __bashswift_isfile


def __bashswift_isdir(path):
    return os.path.__bashswift_isdir_original(__bashswift_redirect(path))


os.path.isdir = __bashswift_isdir


def __bashswift_stat(path, *args, **kwargs):
    return os.__bashswift_stat_original(__bashswift_redirect(path), *args, **kwargs)


os.stat = __bashswift_stat


def __bashswift_mkdir(path, *args, **kwargs):
    return os.__bashswift_mkdir_original(__bashswift_redirect(path), *args, **kwargs)


os.mkdir = __bashswift_mkdir


def __bashswift_makedirs(path, *args, **kwargs):
    return os.__bashswift_makedirs_original(__bashswift_redirect(path), *args, **kwargs)


os.makedirs = __bashswift_makedirs


def __bashswift_remove(path, *args, **kwargs):
    return os.__bashswift_remove_original(__bashswift_redirect(path), *args, **kwargs)


os.remove = __bashswift_remove


def __bashswift_rmdir(path, *args, **kwargs):
    return os.__bashswift_rmdir_original(__bashswift_redirect(path), *args, **kwargs)


os.rmdir = __bashswift_rmdir

try:
    os.chdir('/host' + (_payload.get('cwd') or '/'))
except Exception:
    os.chdir('/host')

sys.argv = [(_payload.get('scriptPath') or 'python3')] + list(_payload.get('arguments') or [])
sys.stdin = io.StringIO(_payload.get('stdin') or '')

_stdout = io.StringIO()
_stderr = io.StringIO()
_orig_stdout, _orig_stderr = sys.stdout, sys.stderr
sys.stdout, sys.stderr = _stdout, _stderr

_exit_code = 0

try:
    if _payload.get('mode') == 'module':
        runpy.run_module(_payload.get('source') or '', run_name='__main__')
    else:
        _script_name = _payload.get('scriptPath') or '<string>'
        _code = _payload.get('source') or ''
        exec(compile(_code, _script_name, 'exec'), {'__name__': '__main__'})
except SystemExit as _system_exit:
    _code = _system_exit.code
    if _code is None:
        _exit_code = 0
    elif isinstance(_code, int):
        _exit_code = int(_code)
    else:
        _exit_code = 1
        print(_code, file=sys.stderr)
except Exception:
    traceback.print_exc()
    _exit_code = 1
finally:
    sys.stdout, sys.stderr = _orig_stdout, _orig_stderr

__bashswift_result_json = json.dumps({
    'stdout': _stdout.getvalue(),
    'stderr': _stderr.getvalue(),
    'exitCode': _exit_code,
})
      `);

      const resultProxy = pyodide.globals.get('__bashswift_result_json');
      const result = String(resultProxy);
      if (resultProxy && typeof resultProxy.destroy === 'function') {
        resultProxy.destroy();
      }
      pyodide.globals.delete('__bashswift_payload_json');
      pyodide.globals.delete('__bashswift_result_json');
      return result;
    }
"""#
}
