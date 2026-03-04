import Foundation
import Bash
import BashCPythonBridge

#if canImport(Darwin)
import Darwin
#endif

public struct CPythonConfiguration: Sendable {
    public var strictFilesystem: Bool

    public init(strictFilesystem: Bool = true) {
        self.strictFilesystem = strictFilesystem
    }

    public static let `default` = CPythonConfiguration()
}

private enum CPythonRuntimeError: LocalizedError {
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

private let cpythonFilesystemCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafePointer<CChar>? = {
    context, request in
    guard let context,
          let request
    else {
        guard let pointer = strdup("{\"ok\":false,\"error\":\"invalid bridge callback payload\"}") else {
            return nil
        }
        return UnsafePointer(pointer)
    }

    let bridge = Unmanaged<CPythonFilesystemBridge>.fromOpaque(context).takeUnretainedValue()
    let requestJSON = String(cString: request)
    let responseJSON = bridge.handle(requestJSON: requestJSON)
    guard let pointer = strdup(responseJSON) else {
        return nil
    }
    return UnsafePointer(pointer)
}

public actor CPythonRuntime: PythonRuntime {
    private let configuration: CPythonConfiguration
    private let filesystemBridge = CPythonFilesystemBridge()

    private var runtime: OpaquePointer?
    private var initializationError: String?

    public init(configuration: CPythonConfiguration = .default) {
        self.configuration = configuration
    }

    public static func isAvailable() -> Bool {
        bash_cpython_is_available() == 1
    }

    public func versionString() async -> String {
        do {
            let runtime = try ensureRuntime()
            var errorPointer: UnsafeMutablePointer<CChar>?
            let pointer = bash_cpython_runtime_version(runtime, &errorPointer)
            defer {
                if let errorPointer {
                    bash_cpython_free_string(errorPointer)
                }
            }

            guard let pointer else {
                if let errorPointer {
                    return "Python 3 (CPython unavailable: \(String(cString: errorPointer)))"
                }
                return "Python 3 (CPython)"
            }

            defer { bash_cpython_free_string(pointer) }
            let raw = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                return "Python 3 (CPython)"
            }
            return "Python \(raw)"
        } catch {
            return "Python 3 (CPython unavailable: \(error.localizedDescription))"
        }
    }

    public func execute(
        request: PythonExecutionRequest,
        filesystem: any ShellFilesystem
    ) async -> PythonExecutionResult {
        do {
            let runtime = try ensureRuntime()

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
                "strict": configuration.strictFilesystem,
            ]

            let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let payloadJSON = String(decoding: payloadData, as: UTF8.self)

            let bridgeContext = Unmanaged.passUnretained(filesystemBridge).toOpaque()
            bash_cpython_runtime_set_fs_handler(runtime, cpythonFilesystemCallback, bridgeContext)

            var errorPointer: UnsafeMutablePointer<CChar>?
            let resultPointer = payloadJSON.withCString { payloadCString in
                bash_cpython_runtime_execute(runtime, payloadCString, &errorPointer)
            }
            defer {
                if let errorPointer {
                    bash_cpython_free_string(errorPointer)
                }
            }

            guard let resultPointer else {
                let message = errorPointer.map { String(cString: $0) } ?? "unknown CPython runtime error"
                throw CPythonRuntimeError.executionFailed(message)
            }

            defer { bash_cpython_free_string(resultPointer) }
            let resultJSON = String(cString: resultPointer)
            return try decodeExecutionResult(from: resultJSON)
        } catch {
            return PythonExecutionResult(
                stdout: "",
                stderr: "python3: \(error.localizedDescription)\n",
                exitCode: 1
            )
        }
    }

    private func ensureRuntime() throws -> OpaquePointer {
        if let runtime {
            return runtime
        }

        if let initializationError {
            throw CPythonRuntimeError.initializationFailed(initializationError)
        }

        guard CPythonRuntime.isAvailable() else {
            let message = "embedded CPython is unavailable on this platform/build"
            initializationError = message
            throw CPythonRuntimeError.unavailable(message)
        }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let runtimePointer = CPythonScripts.bootstrapScript.withCString { bootstrapCString in
            bash_cpython_runtime_create(bootstrapCString, &errorPointer)
        }

        defer {
            if let errorPointer {
                bash_cpython_free_string(errorPointer)
            }
        }

        guard let runtimePointer else {
            let message = errorPointer.map { String(cString: $0) } ?? "failed to initialize embedded CPython runtime"
            initializationError = message
            throw CPythonRuntimeError.initializationFailed(message)
        }

        runtime = runtimePointer
        return runtimePointer
    }

    private func decodeExecutionResult(from resultJSON: String) throws -> PythonExecutionResult {
        guard let data = resultJSON.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CPythonRuntimeError.executionFailed("invalid Python runtime response")
        }

        let stdout = object["stdout"] as? String ?? ""
        let stderr = object["stderr"] as? String ?? ""
        let exitCode = (object["exitCode"] as? NSNumber)?.int32Value ?? 1

        return PythonExecutionResult(stdout: stdout, stderr: stderr, exitCode: exitCode)
    }
}

private final class CPythonFilesystemBridge: @unchecked Sendable {
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
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.readFile(path: path)
                }
                return response(success: ["dataBase64": data.base64EncodedString()])

            case "writeFile":
                let path = try resolvedPath(from: object)
                let decoded = Data(base64Encoded: object["dataBase64"] as? String ?? "") ?? Data()
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.writeFile(path: path, data: decoded, append: false)
                }
                return response(success: [:])

            case "appendFile":
                let path = try resolvedPath(from: object)
                let decoded = Data(base64Encoded: object["dataBase64"] as? String ?? "") ?? Data()
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.writeFile(path: path, data: decoded, append: true)
                }
                return response(success: [:])

            case "stat", "lstat":
                let path = try resolvedPath(from: object)
                let info = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
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
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.listDirectory(path: path).map(\.name).sorted()
                }
                return response(success: ["entries": entries])

            case "mkdir":
                let path = try resolvedPath(from: object)
                let recursive = object["recursive"] as? Bool ?? false
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
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
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
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
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.createSymlink(path: path, target: target)
                }
                return response(success: [:])

            case "readlink":
                let path = try resolvedPath(from: object)
                let target = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    return try await filesystem.readSymlink(path: path)
                }
                return response(success: ["target": target])

            case "chmod":
                let path = try resolvedPath(from: object)
                let mode = object["mode"] as? Int ?? 0o644
                try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
                    }
                    try await filesystem.setPermissions(path: path, permissions: mode)
                }
                return response(success: [:])

            case "realpath":
                let path = try resolvedPath(from: object)
                let value = try runBlocking {
                    guard let filesystem = self.snapshot().filesystem else {
                        throw CPythonRuntimeError.unavailable("filesystem bridge is not active")
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
        guard let path = payload["path"] as? String else {
            throw CPythonRuntimeError.executionFailed("filesystem path is required")
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
            throw CPythonRuntimeError.executionFailed("filesystem operation did not produce a result")
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

private enum CPythonScripts {
    static let bootstrapScript = #"""
import base64
import builtins
import io
import importlib.abc
import importlib.util
import json
import os
import posixpath
import runpy
import stat as _stat
import sys
import tempfile as _tempfile
import traceback
import uuid

from _bashswift_host import fs_call as _bashswift_fs_call_raw

_BASHSWIFT_STATE = {
    'cwd': '/',
}


def _b64encode(data):
    return base64.b64encode(data).decode('ascii')


def _b64decode(text):
    if not text:
        return b''
    return base64.b64decode(text.encode('ascii'))


def _resolve_path(path, cwd=None):
    if path is None:
        path = ''
    if not isinstance(path, str):
        path = os.fspath(path)

    base = cwd or _BASHSWIFT_STATE['cwd']
    if not path:
        normalized = posixpath.normpath(base)
    elif path.startswith('/'):
        normalized = posixpath.normpath(path)
    else:
        normalized = posixpath.normpath(posixpath.join(base, path))

    return '/' if normalized in ('', '.') else normalized


def _fs_call(op, payload=None):
    request = {'op': op}
    if payload:
        request.update(payload)

    raw = _bashswift_fs_call_raw(json.dumps(request, sort_keys=True))
    response = json.loads(raw or '{}')
    if not response.get('ok'):
        message = response.get('error') or 'filesystem bridge error'
        raise OSError(message)
    return response


def _read_file_bytes(path):
    response = _fs_call('readFile', {'path': path})
    return _b64decode(response.get('dataBase64', ''))


def _write_file_bytes(path, data):
    _fs_call('writeFile', {'path': path, 'dataBase64': _b64encode(data)})


def _stat_payload(path, follow_symlinks=True):
    op = 'stat' if follow_symlinks else 'lstat'
    return _fs_call(op, {'path': path}).get('stat') or {}


def _to_stat_result(payload):
    mode = int(payload.get('mode', 0)) & 0o777
    if payload.get('isDirectory'):
        mode |= _stat.S_IFDIR
    elif payload.get('isSymbolicLink'):
        mode |= _stat.S_IFLNK
    else:
        mode |= _stat.S_IFREG

    size = int(payload.get('size', 0))
    mtime = float(payload.get('mtime', 0.0))
    return os.stat_result((mode, 0, 0, 1, 0, 0, size, mtime, mtime, mtime))


def _exists(path):
    return bool(_fs_call('exists', {'path': path}).get('exists'))


def _isdir(path):
    try:
        payload = _stat_payload(path, follow_symlinks=True)
        return bool(payload.get('isDirectory'))
    except OSError:
        return False


def _isfile(path):
    try:
        payload = _stat_payload(path, follow_symlinks=True)
        return bool(payload.get('isFile'))
    except OSError:
        return False


def _islink(path):
    try:
        payload = _stat_payload(path, follow_symlinks=False)
        return bool(payload.get('isSymbolicLink'))
    except OSError:
        return False


def _is_path_like(value):
    return isinstance(value, (str, bytes)) or hasattr(value, '__fspath__')


def _first_path_argument(arguments, default=None):
    for value in arguments:
        if _is_path_like(value):
            return value
    return default


def _first_n_path_arguments(arguments, count):
    values = []
    for value in arguments:
        if _is_path_like(value):
            values.append(value)
            if len(values) == count:
                return values
    return values


class _VirtualFile:
    def __init__(self, path, mode='r', encoding=None, errors=None, newline=None):
        self._path = _resolve_path(path)
        self._mode = mode or 'r'
        self._binary = 'b' in self._mode
        self._closed = False
        self._dirty = False

        self._readable = any(flag in self._mode for flag in ('r', '+')) or not any(flag in self._mode for flag in ('w', 'a', 'x'))
        self._writable = any(flag in self._mode for flag in ('w', 'a', 'x', '+'))

        file_exists = _exists(self._path)

        if 'x' in self._mode and file_exists:
            raise FileExistsError(self._path)

        if 'w' in self._mode:
            initial = b''
        elif 'a' in self._mode:
            initial = _read_file_bytes(self._path) if file_exists else b''
        elif file_exists:
            initial = _read_file_bytes(self._path)
        else:
            raise FileNotFoundError(self._path)

        self._bytes = io.BytesIO(initial)
        self._text = None

        if not self._binary:
            self._text = io.TextIOWrapper(
                self._bytes,
                encoding=encoding or 'utf-8',
                errors=errors or 'strict',
                newline=newline,
                write_through=True,
            )

        if 'a' in self._mode:
            self.seek(0, io.SEEK_END)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()

    def __del__(self):
        try:
            self.close()
        except Exception:
            pass

    @property
    def closed(self):
        return self._closed

    @property
    def mode(self):
        return self._mode

    @property
    def name(self):
        return self._path

    def readable(self):
        return self._readable

    def writable(self):
        return self._writable

    def seekable(self):
        return True

    def flush(self):
        if self._closed:
            return
        if self._text is not None:
            self._text.flush()
        if self._writable and self._dirty:
            _write_file_bytes(self._path, self._bytes.getvalue())
            self._dirty = False

    def close(self):
        if self._closed:
            return
        self.flush()
        if self._text is not None:
            self._text.detach()
        self._closed = True

    def read(self, size=-1):
        if self._closed:
            raise ValueError('I/O operation on closed file.')
        if not self._readable:
            raise OSError('file not open for reading')
        if self._binary:
            return self._bytes.read(size)
        return self._text.read(size)

    def readline(self, size=-1):
        if self._binary:
            return self._bytes.readline(size)
        return self._text.readline(size)

    def readlines(self):
        return list(self)

    def write(self, value):
        if self._closed:
            raise ValueError('I/O operation on closed file.')
        if not self._writable:
            raise OSError('file not open for writing')
        self._dirty = True
        if self._binary:
            if isinstance(value, str):
                raise TypeError('a bytes-like object is required, not str')
            return self._bytes.write(value)
        if not isinstance(value, str):
            value = str(value)
        return self._text.write(value)

    def writelines(self, lines):
        for line in lines:
            self.write(line)

    def seek(self, offset, whence=io.SEEK_SET):
        if self._binary:
            return self._bytes.seek(offset, whence)
        return self._text.seek(offset, whence)

    def tell(self):
        if self._binary:
            return self._bytes.tell()
        return self._text.tell()

    def __iter__(self):
        return self

    def __next__(self):
        line = self.readline()
        if line in (b'', ''):
            raise StopIteration
        return line


class _DirEntry:
    def __init__(self, directory_path, name):
        self.name = name
        self.path = _resolve_path(posixpath.join(directory_path, name))

    def inode(self):
        return 0

    def is_dir(self, follow_symlinks=True):
        payload = _stat_payload(self.path, follow_symlinks=follow_symlinks)
        return bool(payload.get('isDirectory'))

    def is_file(self, follow_symlinks=True):
        payload = _stat_payload(self.path, follow_symlinks=follow_symlinks)
        return bool(payload.get('isFile'))

    def is_symlink(self):
        payload = _stat_payload(self.path, follow_symlinks=False)
        return bool(payload.get('isSymbolicLink'))

    def stat(self, follow_symlinks=True):
        payload = _stat_payload(self.path, follow_symlinks=follow_symlinks)
        return _to_stat_result(payload)


class _ScandirIterator:
    def __init__(self, directory_path):
        self._directory_path = directory_path
        names = _fs_call('readdir', {'path': directory_path}).get('entries') or []
        self._entries = [_DirEntry(directory_path, name) for name in names]
        self._index = 0

    def __iter__(self):
        return self

    def __next__(self):
        if self._index >= len(self._entries):
            raise StopIteration
        entry = self._entries[self._index]
        self._index += 1
        return entry

    def close(self):
        self._entries = []

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self.close()


class _BashSwiftLoader(importlib.abc.Loader):
    def __init__(self, path, is_package):
        self.path = path
        self._is_package = is_package

    def create_module(self, spec):
        return None

    def is_package(self, fullname):
        del fullname
        return self._is_package

    def get_filename(self, fullname):
        del fullname
        return self.path

    def get_source(self, fullname):
        del fullname
        return _read_file_bytes(self.path).decode('utf-8')

    def get_code(self, fullname):
        source = self.get_source(fullname)
        return compile(source, self.path, 'exec')

    def exec_module(self, module):
        code = self.get_code(module.__name__)
        module.__file__ = self.path
        if self._is_package:
            module.__path__ = [posixpath.dirname(self.path)]
        exec(code, module.__dict__)


class _BashSwiftFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        del target
        parts = fullname.split('.')
        relative = '/'.join(parts)

        search_paths = path if path is not None else sys.path
        for base in search_paths:
            if not isinstance(base, str) or not base.startswith('/'):
                continue

            module_path = _resolve_path(posixpath.join(base, relative + '.py'))
            if _exists(module_path):
                loader = _BashSwiftLoader(module_path, False)
                return importlib.util.spec_from_loader(fullname, loader, origin=module_path)

            package_init = _resolve_path(posixpath.join(base, relative, '__init__.py'))
            if _exists(package_init):
                loader = _BashSwiftLoader(package_init, True)
                spec = importlib.util.spec_from_loader(fullname, loader, origin=package_init)
                if spec is not None:
                    spec.submodule_search_locations = [_resolve_path(posixpath.join(base, relative))]
                return spec

        return None


def _install_import_finder():
    for finder in sys.meta_path:
        if isinstance(finder, _BashSwiftFinder):
            return
    sys.meta_path.insert(0, _BashSwiftFinder())


def _blocked(*args, **kwargs):
    del args, kwargs
    raise PermissionError('operation disabled in BashPython strict mode')


def _patch_runtime():
    builtins.open = _bashswift_open
    io.open = _bashswift_open

    os.getcwd = lambda: _BASHSWIFT_STATE['cwd']

    def _chdir(path):
        candidate = _resolve_path(path)
        if not _exists(candidate):
            raise FileNotFoundError(candidate)
        if not _isdir(candidate):
            raise NotADirectoryError(candidate)
        _BASHSWIFT_STATE['cwd'] = candidate
        os.environ['PWD'] = candidate

    os.chdir = _chdir

    def _listdir(*args):
        path = _first_path_argument(args, '.')
        directory = _resolve_path(path)
        return _fs_call('readdir', {'path': directory}).get('entries') or []

    os.listdir = _listdir

    def _mkdir(*args, mode=0o777, dir_fd=None):
        del mode, dir_fd
        path = _first_path_argument(args)
        if path is None:
            raise TypeError('mkdir() missing required path argument')
        _fs_call('mkdir', {'path': _resolve_path(path), 'recursive': False})

    os.mkdir = _mkdir

    def _makedirs(name, mode=0o777, exist_ok=False):
        del mode
        path = _resolve_path(name)
        if exist_ok and _exists(path):
            if not _isdir(path):
                raise FileExistsError(path)
            return
        _fs_call('mkdir', {'path': path, 'recursive': True})

    os.makedirs = _makedirs

    def _remove(*args, dir_fd=None):
        del dir_fd
        path = _first_path_argument(args)
        if path is None:
            raise TypeError('remove() missing required path argument')
        _fs_call('rm', {'path': _resolve_path(path), 'recursive': False, 'force': False})

    os.remove = _remove
    os.unlink = _remove

    def _rmdir(*args, dir_fd=None):
        del dir_fd
        path = _first_path_argument(args)
        if path is None:
            raise TypeError('rmdir() missing required path argument')
        _fs_call('rm', {'path': _resolve_path(path), 'recursive': False, 'force': False})

    os.rmdir = _rmdir

    def _stat(*args, dir_fd=None, follow_symlinks=True):
        del dir_fd
        path = _first_path_argument(args)
        if path is None:
            raise TypeError('stat() missing required path argument')
        payload = _stat_payload(_resolve_path(path), follow_symlinks=follow_symlinks)
        return _to_stat_result(payload)

    os.stat = _stat

    def _lstat(*args):
        path = _first_path_argument(args)
        if path is None:
            raise TypeError('lstat() missing required path argument')
        payload = _stat_payload(_resolve_path(path), follow_symlinks=False)
        return _to_stat_result(payload)

    os.lstat = _lstat

    def _chmod(*args, mode=0o777, dir_fd=None, follow_symlinks=True):
        del dir_fd, follow_symlinks
        path = _first_path_argument(args)
        if path is None:
            raise TypeError('chmod() missing required path argument')
        for value in args:
            if isinstance(value, int):
                mode = value
                break
        _fs_call('chmod', {'path': _resolve_path(path), 'mode': int(mode)})

    os.chmod = _chmod

    def _readlink(*args, dir_fd=None):
        del dir_fd
        path = _first_path_argument(args)
        if path is None:
            raise TypeError('readlink() missing required path argument')
        return _fs_call('readlink', {'path': _resolve_path(path)}).get('target', '')

    os.readlink = _readlink

    def _symlink(*args, target_is_directory=False, dir_fd=None):
        del target_is_directory, dir_fd
        values = _first_n_path_arguments(args, 2)
        if len(values) < 2:
            raise TypeError('symlink() missing required src or dst argument')
        src, dst = values[0], values[1]
        _fs_call('symlink', {'path': _resolve_path(dst), 'target': str(src)})

    os.symlink = _symlink

    os.path.exists = lambda path: _exists(_resolve_path(path))
    os.path.isfile = lambda path: _isfile(_resolve_path(path))
    os.path.isdir = lambda path: _isdir(_resolve_path(path))
    os.path.islink = lambda path: _islink(_resolve_path(path))
    os.path.realpath = lambda path: _fs_call('realpath', {'path': _resolve_path(path)}).get('path', _resolve_path(path))

    def _scandir(*args):
        path = _first_path_argument(args, '.')
        return _ScandirIterator(_resolve_path(path))

    os.scandir = _scandir

    os.system = _blocked
    os.popen = _blocked
    os.spawnl = _blocked
    os.spawnlp = _blocked
    os.spawnv = _blocked
    os.spawnvp = _blocked

    _tempfile.gettempdir = lambda: '/tmp'

    def _mkdtemp(suffix='', prefix='tmp', dir=None):
        suffix = suffix or ''
        prefix = prefix or 'tmp'
        base = _resolve_path(dir or '/tmp')
        _fs_call('mkdir', {'path': base, 'recursive': True})
        for _ in range(128):
            candidate = _resolve_path(posixpath.join(base, f"{prefix}{uuid.uuid4().hex}{suffix}"))
            if not _exists(candidate):
                _fs_call('mkdir', {'path': candidate, 'recursive': False})
                return candidate
        raise FileExistsError('unable to create temporary directory')

    class _TemporaryDirectory:
        def __init__(self, suffix='', prefix='tmp', dir=None):
            self.name = _mkdtemp(suffix=suffix, prefix=prefix, dir=dir)
            self._closed = False

        def cleanup(self):
            if self._closed:
                return
            _fs_call('rm', {'path': self.name, 'recursive': True, 'force': True})
            self._closed = True

        def __enter__(self):
            return self.name

        def __exit__(self, exc_type, exc, tb):
            self.cleanup()

    _tempfile.mkdtemp = _mkdtemp
    _tempfile.TemporaryDirectory = _TemporaryDirectory

    blocked_modules = {'subprocess', 'ctypes'}
    original_import = builtins.__import__

    def _strict_import(name, globals=None, locals=None, fromlist=(), level=0):
        root = (name or '').split('.', 1)[0]
        if root in blocked_modules:
            raise ImportError(f"module '{root}' is disabled in BashPython strict mode")
        return original_import(name, globals, locals, fromlist, level)

    builtins.__import__ = _strict_import

    _install_import_finder()


def _bashswift_open(path, mode='r', buffering=-1, encoding=None, errors=None, newline=None, closefd=True, opener=None):
    del buffering, closefd, opener

    if isinstance(path, int):
        raise OSError('file descriptors are not supported in BashPython strict mode')

    resolved = _resolve_path(path)
    return _VirtualFile(
        resolved,
        mode=mode,
        encoding=encoding,
        errors=errors,
        newline=newline,
    )


_patch_runtime()


def __bashswift_execute(request_json):
    payload = json.loads(request_json or '{}')

    requested_cwd = payload.get('cwd') or '/'
    _BASHSWIFT_STATE['cwd'] = _resolve_path(requested_cwd, cwd='/')

    env = payload.get('env') or {}
    if isinstance(env, dict):
        os.environ.clear()
        for key, value in env.items():
            os.environ[str(key)] = str(value)
    os.environ['PWD'] = _BASHSWIFT_STATE['cwd']

    script_path = payload.get('scriptPath') or ''
    source = payload.get('source') or ''
    arguments = list(payload.get('arguments') or [])

    argv0 = script_path or 'python3'
    sys.argv = [argv0] + arguments

    cwd_path = _BASHSWIFT_STATE['cwd']
    while cwd_path in sys.path:
        sys.path.remove(cwd_path)
    sys.path.insert(0, cwd_path)

    if script_path and script_path not in ('-c', '<stdin>'):
        script_abs = _resolve_path(script_path)
        script_dir = posixpath.dirname(script_abs) or '/'
        while script_dir in sys.path:
            sys.path.remove(script_dir)
        sys.path.insert(0, script_dir)

    stdin_text = payload.get('stdin') or ''
    sys.stdin = io.StringIO(stdin_text)

    stdout_capture = io.StringIO()
    stderr_capture = io.StringIO()
    original_stdout = sys.stdout
    original_stderr = sys.stderr

    exit_code = 0

    try:
        sys.stdout = stdout_capture
        sys.stderr = stderr_capture

        if payload.get('mode') == 'module':
            runpy.run_module(source, run_name='__main__')
        else:
            script_name = script_path or '<string>'
            globals_dict = {'__name__': '__main__'}
            if script_name not in ('-c', '<stdin>', '<string>'):
                globals_dict['__file__'] = _resolve_path(script_name)
            exec(compile(source, script_name, 'exec'), globals_dict)
    except SystemExit as system_exit:
        code = system_exit.code
        if code is None:
            exit_code = 0
        elif isinstance(code, int):
            exit_code = int(code)
        else:
            exit_code = 1
            print(code, file=stderr_capture)
    except Exception:
        traceback.print_exc(file=stderr_capture)
        exit_code = 1
    finally:
        sys.stdout = original_stdout
        sys.stderr = original_stderr

    return json.dumps(
        {
            'stdout': stdout_capture.getvalue(),
            'stderr': stderr_capture.getvalue(),
            'exitCode': int(exit_code),
        },
        sort_keys=True,
    )
"""#
}
