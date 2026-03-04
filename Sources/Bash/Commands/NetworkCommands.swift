import ArgumentParser
import Foundation

struct CurlCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.short, .long], help: "Silent mode")
        var silent = false

        @Flag(name: [.customShort("S"), .customLong("show-error")], help: "Show errors when used with -s")
        var showError = false

        @Flag(name: [.short, .customLong("include")], help: "Include response headers in output")
        var include = false

        @Flag(name: [.customShort("I"), .customLong("head")], help: "Use HEAD request")
        var head = false

        @Flag(name: [.short, .long], help: "Fail on HTTP response code >= 400")
        var fail = false

        @Flag(name: [.customShort("L"), .customLong("location")], help: "Follow redirects")
        var location = false

        @Option(name: [.customShort("X"), .customLong("request")], help: "Specify request method")
        var request: String?

        @Option(name: [.customShort("H"), .customLong("header")], help: "Pass custom header(s)")
        var headers: [String] = []

        @Option(name: [.customShort("A"), .customLong("user-agent")], help: "Set User-Agent header")
        var userAgent: String?

        @Option(name: [.customShort("e"), .customLong("referer")], help: "Set Referer header")
        var referer: String?

        @Option(name: [.customShort("u"), .customLong("user")], help: "Server user and password")
        var user: String?

        @Option(name: [.customShort("b"), .customLong("cookie")], help: "Send cookies")
        var cookie: String?

        @Option(name: [.customShort("c"), .customLong("cookie-jar")], help: "Write cookies to this file after operation")
        var cookieJar: String?

        @Option(name: [.customShort("d"), .customLong("data")], help: "HTTP request body data")
        var data: [String] = []

        @Option(name: [.customLong("data-raw")], help: "HTTP request body data, '@' has no special meaning")
        var dataRaw: [String] = []

        @Option(name: [.customLong("data-binary")], help: "HTTP request body data, preserving binary form")
        var dataBinary: [String] = []

        @Option(name: [.customLong("data-urlencode")], help: "HTTP request body data URL-encoded")
        var dataUrlEncoded: [String] = []

        @Option(name: [.customShort("T"), .customLong("upload-file")], help: "Transfer local FILE to destination")
        var uploadFile: String?

        @Option(name: [.customShort("F"), .customLong("form")], help: "Specify multipart MIME data")
        var form: [String] = []

        @Option(name: [.short, .long], help: "Write body to file")
        var output: String?

        @Flag(name: [.customShort("O"), .customLong("remote-name")], help: "Write output to file named as remote file")
        var remoteName = false

        @Option(name: [.customShort("w"), .customLong("write-out")], help: "Output format after completion")
        var writeOut: String?

        @Option(name: [.customShort("m"), .customLong("max-time")], help: "Maximum request time in seconds")
        var maxTime: Double?

        @Option(name: [.customLong("connect-timeout")], help: "Maximum time allowed for connection")
        var connectTimeout: Double?

        @Option(name: [.customLong("max-redirs")], help: "Maximum redirects to follow")
        var maxRedirs: Int?

        @Flag(name: [.customShort("v"), .customLong("verbose")], help: "Make the operation more talkative")
        var verbose = false

        @Argument(help: "URL to fetch")
        var url: String?
    }

    static let name = "curl"
    static let overview = "Transfer data from or to a URL"

    static func _toAnyBuiltinCommand() -> AnyBuiltinCommand {
        AnyBuiltinCommand(
            name: name,
            aliases: aliases,
            overview: overview
        ) { context, args in
            let normalized = normalizeAttachedValueOptions(args)
            do {
                let options = try Options.parse(normalized)
                return await run(context: &context, options: options)
            } catch {
                let message = Options.fullMessage(for: error)
                if !message.isEmpty {
                    let output = message.hasSuffix("\n") ? message : message + "\n"
                    let exitCode = Options.exitCode(for: error).rawValue
                    if exitCode == 0 {
                        context.writeStdout(output)
                    } else {
                        context.writeStderr(output)
                    }
                }
                return Options.exitCode(for: error).rawValue
            }
        }
    }

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        guard let rawURL = options.url, !rawURL.isEmpty else {
            return emitError(
                &context,
                options: options,
                code: 2,
                message: "curl: no URL specified\n"
            )
        }

        if let maxTime = options.maxTime, maxTime <= 0 {
            return emitError(
                &context,
                options: options,
                code: 2,
                message: "curl: invalid --max-time value: \(maxTime)\n"
            )
        }

        if let connectTimeout = options.connectTimeout, connectTimeout <= 0 {
            return emitError(
                &context,
                options: options,
                code: 2,
                message: "curl: invalid --connect-timeout value: \(connectTimeout)\n"
            )
        }

        if let maxRedirs = options.maxRedirs, maxRedirs < 0 {
            return emitError(
                &context,
                options: options,
                code: 2,
                message: "curl: invalid --max-redirs value: \(maxRedirs)\n"
            )
        }

        let normalizedURL = normalizeURL(rawURL)
        guard let url = URL(string: normalizedURL), let scheme = url.scheme?.lowercased() else {
            return emitError(
                &context,
                options: options,
                code: 3,
                message: "curl: (3) URL rejected: \(rawURL)\n"
            )
        }

        let method = resolvedMethod(options: options)
        let requestBodyResult = await buildRequestBody(
            options: options,
            dataTokens: options.data,
            rawTokens: options.dataRaw,
            binaryTokens: options.dataBinary,
            encodedTokens: options.dataUrlEncoded,
            context: &context
        )
        let requestBody: Data?
        let contentType: String?
        switch requestBodyResult {
        case let .failure(exitCode):
            return exitCode
        case let .success(value):
            requestBody = value.data
            contentType = value.contentType
        }

        let requestHeadersResult = await parseRequestHeaders(
            options: options,
            contentType: contentType,
            context: &context
        )
        let requestHeaders: [String: String]
        switch requestHeadersResult {
        case let .failure(exitCode):
            return exitCode
        case let .success(headers):
            requestHeaders = headers
        }

        let responseResult: CurlOutcome<CurlResponse>
        switch scheme {
        case "data":
            responseResult = fetchDataURL(url: url, method: method)
        case "file":
            responseResult = await fetchFileURL(url: url, method: method, context: &context)
        case "http", "https":
            responseResult = await fetchHTTPURL(
                url: url,
                method: method,
                headers: requestHeaders,
                body: requestBody,
                maxTime: options.maxTime,
                connectTimeout: options.connectTimeout,
                context: &context,
                options: options
            )
        default:
            return emitError(
                &context,
                options: options,
                code: 1,
                message: "curl: unsupported URL scheme: \(scheme)\n"
            )
        }

        let response: CurlResponse
        switch responseResult {
        case let .failure(exitCode):
            return exitCode
        case let .success(value):
            response = value
        }

        if let cookieJar = options.cookieJar, scheme != "http", scheme != "https" {
            let persistResult = await persistCookieJar(
                path: cookieJar,
                context: &context,
                storage: HTTPCookieStorage()
            )
            if case let .failure(exitCode) = persistResult {
                return exitCode
            }
        }

        if options.fail, response.statusCode >= 400 {
            return emitError(
                &context,
                options: options,
                code: 22,
                message: "curl: (22) The requested URL returned error: \(response.statusCode)\n"
            )
        }

        let includeHeaders = options.include || options.head
        let headerData = includeHeaders ? Data(renderHeaders(response: response).utf8) : Data()
        let bodyData = method == "HEAD" ? Data() : response.body
        let outputPath = options.output ?? (options.remoteName ? outputFilename(for: url) : nil)
        if let outputPath {
            do {
                try await context.filesystem.writeFile(
                    path: context.resolvePath(outputPath),
                    data: bodyData,
                    append: false
                )
            } catch {
                return emitError(
                    &context,
                    options: options,
                    code: 23,
                    message: "curl: (\(outputPath)) \(error)\n"
                )
            }

            if includeHeaders {
                context.stdout.append(headerData)
            }

            if let writeOut = options.writeOut {
                let rendered = renderWriteOut(
                    format: writeOut,
                    response: response,
                    requestedURL: normalizedURL
                )
                context.stdout.append(Data(rendered.utf8))
            }
            return 0
        }

        context.stdout.append(headerData)
        context.stdout.append(bodyData)
        if let writeOut = options.writeOut {
            let rendered = renderWriteOut(
                format: writeOut,
                response: response,
                requestedURL: normalizedURL
            )
            context.stdout.append(Data(rendered.utf8))
        }
        return 0
    }

    private struct CurlResponse {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        var effectiveURL: String
        var reasonPhrase: String
    }

    private enum CurlOutcome<Value> {
        case success(Value)
        case failure(Int32)
    }

    private final class CurlRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let followRedirects: Bool
        let maxRedirects: Int?
        private(set) var exceededMaxRedirects = false
        private var redirectCount = 0

        init(followRedirects: Bool, maxRedirects: Int?) {
            self.followRedirects = followRedirects
            self.maxRedirects = maxRedirects
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard followRedirects else {
                completionHandler(nil)
                return
            }

            if let maxRedirects, redirectCount >= maxRedirects {
                exceededMaxRedirects = true
                completionHandler(nil)
                return
            }

            redirectCount += 1
            completionHandler(request)
        }
    }

    private static func normalizeURL(_ raw: String) -> String {
        if raw.hasPrefix("data:") || raw.hasPrefix("file:") || raw.contains("://") {
            return raw
        }
        return "https://\(raw)"
    }

    private static let shortOptionsRequiringAttachedValue: Set<Character> = [
        "X", "H", "A", "e", "u", "b", "c", "d", "T", "F", "o", "w", "m",
    ]

    private static func normalizeAttachedValueOptions(_ args: [String]) -> [String] {
        var output: [String] = []
        var passthrough = false

        for arg in args {
            if passthrough {
                output.append(arg)
                continue
            }

            if arg == "--" {
                passthrough = true
                output.append(arg)
                continue
            }

            guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 else {
                output.append(arg)
                continue
            }

            let optionCharacter = arg[arg.index(after: arg.startIndex)]
            guard shortOptionsRequiringAttachedValue.contains(optionCharacter) else {
                output.append(arg)
                continue
            }

            let valueStart = arg.index(arg.startIndex, offsetBy: 2)
            let value = String(arg[valueStart...])
            guard !value.isEmpty else {
                output.append(arg)
                continue
            }

            output.append("-\(optionCharacter)")
            output.append(value)
        }

        return output
    }

    private static func resolvedMethod(options: Options) -> String {
        if let explicit = options.request, !explicit.isEmpty {
            return explicit.uppercased()
        }
        if options.head {
            return "HEAD"
        }
        if options.uploadFile != nil {
            return "PUT"
        }
        let hasBodyData =
            !options.data.isEmpty ||
            !options.dataRaw.isEmpty ||
            !options.dataBinary.isEmpty ||
            !options.dataUrlEncoded.isEmpty ||
            !options.form.isEmpty
        return hasBodyData ? "POST" : "GET"
    }

    private static func buildRequestBody(
        options: Options,
        dataTokens: [String],
        rawTokens: [String],
        binaryTokens: [String],
        encodedTokens: [String],
        context: inout CommandContext
    ) async -> CurlOutcome<(data: Data?, contentType: String?)> {
        if let uploadFile = options.uploadFile {
            let uploadPath = context.resolvePath(uploadFile)
            do {
                let uploadData = try await context.filesystem.readFile(path: uploadPath)
                return .success((uploadData, "application/octet-stream"))
            } catch {
                context.writeStderr("curl: \(uploadFile): \(error)\n")
                return .failure(26)
            }
        }

        if !options.form.isEmpty {
            let formBody = await buildMultipartFormBody(fields: options.form, context: &context)
            switch formBody {
            case let .failure(exitCode):
                return .failure(exitCode)
            case let .success(value):
                return .success((value.body, "multipart/form-data; boundary=\(value.boundary)"))
            }
        }

        guard !dataTokens.isEmpty || !rawTokens.isEmpty || !binaryTokens.isEmpty || !encodedTokens.isEmpty else {
            return .success((nil, nil))
        }

        var chunks: [Data] = []
        for token in dataTokens {
            if token == "@-" {
                chunks.append(context.stdin)
                continue
            }

            if token.hasPrefix("@") {
                let source = String(token.dropFirst())
                do {
                    let fileData = try await context.filesystem.readFile(path: context.resolvePath(source))
                    chunks.append(fileData)
                } catch {
                    context.writeStderr("curl: @\(source): \(error)\n")
                    return .failure(26)
                }
                continue
            }

            let resolvedToken: String
            do {
                resolvedToken = try await resolveSecretReferences(in: token, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }

            chunks.append(Data(resolvedToken.utf8))
        }

        for token in rawTokens {
            if token == "@-" {
                chunks.append(context.stdin)
            } else {
                let resolvedToken: String
                do {
                    resolvedToken = try await resolveSecretReferences(in: token, context: &context)
                } catch {
                    context.writeStderr("curl: \(error)\n")
                    return .failure(1)
                }

                chunks.append(Data(resolvedToken.utf8))
            }
        }

        for token in binaryTokens {
            if token == "@-" {
                chunks.append(context.stdin)
                continue
            }

            if token.hasPrefix("@") {
                let source = String(token.dropFirst())
                do {
                    let fileData = try await context.filesystem.readFile(path: context.resolvePath(source))
                    chunks.append(fileData)
                } catch {
                    context.writeStderr("curl: @\(source): \(error)\n")
                    return .failure(26)
                }
                continue
            }

            let resolvedToken: String
            do {
                resolvedToken = try await resolveSecretReferences(in: token, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }

            chunks.append(Data(resolvedToken.utf8))
        }

        for token in encodedTokens {
            let resolvedToken: String
            do {
                resolvedToken = try await resolveSecretReferences(in: token, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }

            let encoded = formURLEncode(resolvedToken)
            chunks.append(Data(encoded.utf8))
        }

        var merged = Data()
        for (index, chunk) in chunks.enumerated() {
            if index > 0 {
                merged.append(Data("&".utf8))
            }
            merged.append(chunk)
        }

        let contentType = chunks.isEmpty ? nil : "application/x-www-form-urlencoded"
        return .success((merged, contentType))
    }

    private static func fetchDataURL(url: URL, method: String) -> CurlOutcome<CurlResponse> {
        let absolute = url.absoluteString
        let prefix = "data:"
        guard absolute.hasPrefix(prefix) else {
            return .failure(3)
        }

        let payload = String(absolute.dropFirst(prefix.count))
        guard let commaIndex = payload.firstIndex(of: ",") else {
            return .failure(3)
        }

        let meta = String(payload[..<commaIndex])
        let encoded = String(payload[payload.index(after: commaIndex)...])
        let isBase64 = meta.contains(";base64")

        let body: Data
        if isBase64 {
            guard let decoded = Data(base64Encoded: encoded) else {
                return .failure(3)
            }
            body = decoded
        } else {
            let decoded = encoded.removingPercentEncoding ?? encoded
            body = Data(decoded.utf8)
        }

        var headers: [String: String] = [:]
        let mime = meta.split(separator: ";").first.map(String.init)
        if let mime, !mime.isEmpty {
            headers["Content-Type"] = mime
        }
        headers["Content-Length"] = "\(body.count)"

        let effectiveBody = method == "HEAD" ? Data() : body
        return .success(
            CurlResponse(
                statusCode: 200,
                headers: headers,
                body: effectiveBody,
                effectiveURL: url.absoluteString,
                reasonPhrase: "OK"
            )
        )
    }

    private static func fetchFileURL(
        url: URL,
        method: String,
        context: inout CommandContext
    ) async -> CurlOutcome<CurlResponse> {
        if let host = url.host, !host.isEmpty, host.lowercased() != "localhost" {
            context.writeStderr("curl: remote file host not supported: \(host)\n")
            return .failure(37)
        }

        let decodedPath = url.path.removingPercentEncoding ?? url.path
        guard !decodedPath.isEmpty else {
            context.writeStderr("curl: file URL missing path\n")
            return .failure(3)
        }

        let filesystemPath = PathUtils.normalize(path: decodedPath, currentDirectory: "/")
        do {
            let data = try await context.filesystem.readFile(path: filesystemPath)
            let effectiveBody = method == "HEAD" ? Data() : data
            return .success(
                CurlResponse(
                    statusCode: 200,
                    headers: ["Content-Length": "\(data.count)"],
                    body: effectiveBody,
                    effectiveURL: url.absoluteString,
                    reasonPhrase: "OK"
                )
            )
        } catch {
            context.writeStderr("curl: \(filesystemPath): \(error)\n")
            return .failure(37)
        }
    }

    private static func fetchHTTPURL(
        url: URL,
        method: String,
        headers: [String: String],
        body: Data?,
        maxTime: Double?,
        connectTimeout: Double?,
        context: inout CommandContext,
        options: Options
    ) async -> CurlOutcome<CurlResponse> {
        let cookieStorage = HTTPCookieStorage()
        let cookieLoad = await loadCookies(
            options: options,
            context: &context,
            requestURL: url,
            storage: cookieStorage
        )
        let cookieHeaderFromFile: String?
        switch cookieLoad {
        case let .failure(exitCode):
            return .failure(exitCode)
        case let .success(value):
            cookieHeaderFromFile = value
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.httpCookieAcceptPolicy = .always

        let redirectDelegate = CurlRedirectDelegate(
            followRedirects: options.location,
            maxRedirects: options.maxRedirs ?? 20
        )
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let maxTime {
            request.timeoutInterval = maxTime
        } else if let connectTimeout {
            request.timeoutInterval = connectTimeout
        }

        for key in headers.keys.sorted() {
            if let value = headers[key] {
                request.addValue(value, forHTTPHeaderField: key)
            }
        }
        if let cookieHeaderFromFile {
            request.setValue(cookieHeaderFromFile, forHTTPHeaderField: "Cookie")
        }

        if options.verbose {
            context.writeStderr("> \(method) \(url.absoluteString)\n")
            if let requestHeaders = request.allHTTPHeaderFields {
                for key in requestHeaders.keys.sorted() {
                    if let value = requestHeaders[key] {
                        context.writeStderr("> \(key): \(value)\n")
                    }
                }
            }
            context.writeStderr(">\n")
        }

        do {
            let (data, response) = try await session.data(for: request)

            if redirectDelegate.exceededMaxRedirects {
                return .failure(
                    emitError(
                        &context,
                        options: options,
                        code: 47,
                        message: "curl: (47) Maximum redirects followed\n"
                    )
                )
            }

            guard let http = response as? HTTPURLResponse else {
                return .failure(
                    emitError(
                        &context,
                        options: options,
                        code: 7,
                        message: "curl: non-HTTP response\n"
                    )
                )
            }

            var mappedHeaders: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                let renderedKey = String(describing: key)
                let renderedValue = String(describing: value)
                mappedHeaders[renderedKey] = renderedValue
            }

            if options.verbose {
                context.writeStderr("< HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))\n")
                for key in mappedHeaders.keys.sorted() {
                    if let value = mappedHeaders[key] {
                        context.writeStderr("< \(key): \(value)\n")
                    }
                }
                context.writeStderr("<\n")
            }

            if let cookieJar = options.cookieJar {
                let persistResult = await persistCookieJar(
                    path: cookieJar,
                    context: &context,
                    storage: cookieStorage
                )
                if case let .failure(exitCode) = persistResult {
                    return .failure(exitCode)
                }
            }

            return .success(
                CurlResponse(
                    statusCode: http.statusCode,
                    headers: mappedHeaders,
                    body: data,
                    effectiveURL: http.url?.absoluteString ?? url.absoluteString,
                    reasonPhrase: HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                )
            )
        } catch {
            if redirectDelegate.exceededMaxRedirects {
                return .failure(
                    emitError(
                        &context,
                        options: options,
                        code: 47,
                        message: "curl: (47) Maximum redirects followed\n"
                    )
                )
            }
            return .failure(
                emitError(
                    &context,
                    options: options,
                    code: 7,
                    message: "curl: \(error)\n"
                )
            )
        }
    }

    private static func renderHeaders(response: CurlResponse) -> String {
        var output = "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)\n"
        for key in response.headers.keys.sorted() {
            if let value = response.headers[key] {
                output += "\(key): \(value)\n"
            }
        }
        output += "\n"
        return output
    }

    private static func outputFilename(for url: URL) -> String {
        let candidate = url.lastPathComponent
        if candidate.isEmpty || candidate == "/" {
            return "index.html"
        }
        return candidate
    }

    private static func parseRequestHeaders(
        options: Options,
        contentType: String?,
        context: inout CommandContext
    ) async -> CurlOutcome<[String: String]> {
        var parsed: [String: String] = [:]

        for header in options.headers {
            guard let separator = header.firstIndex(of: ":") else {
                context.writeStderr("curl: invalid header value\n")
                return .failure(2)
            }

            let key = String(header[..<separator]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(header[header.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else {
                context.writeStderr("curl: invalid header value\n")
                return .failure(2)
            }

            let value: String
            do {
                value = try await resolveSecretReferences(in: rawValue, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }
            parsed[key] = value
        }

        if let userAgent = options.userAgent {
            do {
                parsed["User-Agent"] = try await resolveSecretReferences(in: userAgent, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }
        }
        if let referer = options.referer {
            do {
                parsed["Referer"] = try await resolveSecretReferences(in: referer, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }
        }
        if let user = options.user {
            let resolvedUser: String
            do {
                resolvedUser = try await resolveSecretReferences(in: user, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }

            let encoded = Data(resolvedUser.utf8).base64EncodedString()
            parsed["Authorization"] = "Basic \(encoded)"
        }

        if let contentType, headerValue(named: "content-type", in: parsed) == nil {
            parsed["Content-Type"] = contentType
        }

        return .success(parsed)
    }

    private static let secretReferencePrefix = "secretref:v1:"

    private static func resolveSecretReferences(
        in value: String,
        context: inout CommandContext
    ) async throws -> String {
        guard value.contains(secretReferencePrefix) else {
            return value
        }

        var output = ""
        var index = value.startIndex

        while index < value.endIndex {
            guard let prefixRange = value[index...].range(of: secretReferencePrefix) else {
                output += String(value[index...])
                break
            }

            output += String(value[index..<prefixRange.lowerBound])
            var end = prefixRange.upperBound
            while end < value.endIndex, isSecretReferenceCharacter(value[end]) {
                end = value.index(after: end)
            }

            let candidate = String(value[prefixRange.lowerBound..<end])
            if candidate == secretReferencePrefix {
                output += candidate
                index = end
                continue
            }

            if let resolved = try await context.resolveSecretReferenceIfEnabled(candidate) {
                guard let resolvedString = String(data: resolved, encoding: .utf8) else {
                    throw ShellError.unsupported(
                        "secret reference resolved to non-UTF-8 data and cannot be used in curl arguments"
                    )
                }
                output += resolvedString
            } else {
                output += candidate
            }

            index = end
        }

        return output
    }

    private static func isSecretReferenceCharacter(_ character: Character) -> Bool {
        character == "-" || character == "_" || character.isLetter || character.isNumber
    }

    private static func headerValue(named target: String, in headers: [String: String]) -> String? {
        let loweredTarget = target.lowercased()
        return headers.first { key, _ in
            key.lowercased() == loweredTarget
        }?.value
    }

    private static func formURLEncode(_ input: String) -> String {
        if let separator = input.firstIndex(of: "=") {
            let key = String(input[..<separator])
            let value = String(input[input.index(after: separator)...])
            return "\(key)=\(urlEncode(value))"
        }
        return urlEncode(input)
    }

    private static func urlEncode(_ input: String) -> String {
        let disallowed = CharacterSet(charactersIn: "&=+")
        let allowed = CharacterSet.urlQueryAllowed.subtracting(disallowed)
        return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input
    }

    private static func renderWriteOut(
        format: String,
        response: CurlResponse,
        requestedURL: String
    ) -> String {
        var rendered = format
        rendered = rendered.replacingOccurrences(of: "%{http_code}", with: String(response.statusCode))
        rendered = rendered.replacingOccurrences(
            of: "%{content_type}",
            with: headerValue(named: "content-type", in: response.headers) ?? ""
        )
        rendered = rendered.replacingOccurrences(of: "%{url_effective}", with: response.effectiveURL.isEmpty ? requestedURL : response.effectiveURL)
        rendered = rendered.replacingOccurrences(of: "%{size_download}", with: String(response.body.count))
        rendered = rendered.replacingOccurrences(of: "\\n", with: "\n")
        return rendered
    }

    private static func buildMultipartFormBody(
        fields: [String],
        context: inout CommandContext
    ) async -> CurlOutcome<(body: Data, boundary: String)> {
        let boundary = "----BashCurl\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        for field in fields {
            guard let separator = field.firstIndex(of: "=") else {
                context.writeStderr("curl: invalid form field: \(field)\n")
                return .failure(2)
            }

            let name = String(field[..<separator]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else {
                context.writeStderr("curl: invalid form field: \(field)\n")
                return .failure(2)
            }

            let rawValue = String(field[field.index(after: separator)...])
            append("--\(boundary)\r\n")

            if rawValue.hasPrefix("@") {
                let fileSpec = String(rawValue.dropFirst())
                let (filePath, explicitType) = splitFileSpec(fileSpec)
                let resolvedPath = context.resolvePath(filePath)

                let fileData: Data
                do {
                    fileData = try await context.filesystem.readFile(path: resolvedPath)
                } catch {
                    context.writeStderr("curl: \(filePath): \(error)\n")
                    return .failure(26)
                }

                let filename = PathUtils.basename(filePath)
                append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
                append("Content-Type: \(explicitType ?? "application/octet-stream")\r\n\r\n")
                body.append(fileData)
                append("\r\n")
                continue
            }

            let resolvedValue: String
            do {
                resolvedValue = try await resolveSecretReferences(in: rawValue, context: &context)
            } catch {
                context.writeStderr("curl: \(error)\n")
                return .failure(1)
            }

            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append(resolvedValue)
            append("\r\n")
        }

        append("--\(boundary)--\r\n")
        return .success((body, boundary))
    }

    private static func splitFileSpec(_ spec: String) -> (path: String, contentType: String?) {
        guard let typeRange = spec.range(of: ";type=") else {
            return (spec, nil)
        }
        let path = String(spec[..<typeRange.lowerBound])
        let contentType = String(spec[typeRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        return (path, contentType.isEmpty ? nil : contentType)
    }

    private static func loadCookies(
        options: Options,
        context: inout CommandContext,
        requestURL: URL,
        storage: HTTPCookieStorage
    ) async -> CurlOutcome<String?> {
        guard let cookieOption = options.cookie else {
            return .success(nil)
        }

        let treatAsFile: Bool
        let fileReference: String
        if cookieOption.hasPrefix("@") {
            treatAsFile = true
            fileReference = String(cookieOption.dropFirst())
        } else if shouldTreatCookieOptionAsFile(cookieOption) {
            treatAsFile = true
            fileReference = cookieOption
        } else {
            treatAsFile = false
            fileReference = ""
        }

        guard treatAsFile else {
            let literal = cookieOption.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(literal.isEmpty ? nil : literal)
        }

        let cookieData: Data
        do {
            cookieData = try await context.filesystem.readFile(path: context.resolvePath(fileReference))
        } catch {
            context.writeStderr("curl: \(fileReference): \(error)\n")
            return .failure(26)
        }

        guard let cookieText = String(data: cookieData, encoding: .utf8) else {
            return .success(nil)
        }

        let lines = cookieText.split(whereSeparator: \.isNewline).map(String.init)
        var parsedAny = false
        for rawLine in lines {
            if let cookie = parseNetscapeCookieLine(rawLine, defaultHost: requestURL.host ?? "localhost") {
                storage.setCookie(cookie)
                parsedAny = true
            }
        }
        if parsedAny {
            return .success(nil)
        }

        let header = cookieText.trimmingCharacters(in: .whitespacesAndNewlines)
        if header.isEmpty {
            return .success(nil)
        }
        return .success(header)
    }

    private static func shouldTreatCookieOptionAsFile(_ value: String) -> Bool {
        // curl treats `-b NAME=VALUE` as literal cookies and `-b FILE` as a cookie file.
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        if trimmed.contains("=") || trimmed.contains(";") {
            return false
        }
        return true
    }

    private static func persistCookieJar(
        path: String,
        context: inout CommandContext,
        storage: HTTPCookieStorage
    ) async -> CurlOutcome<Void> {
        let cookies = storage.cookies ?? []
        var output = "# Netscape HTTP Cookie File\n"
        output += "# This file was generated by Bash curl\n"

        for cookie in cookies {
            let domain = cookie.domain
            let includeSubdomains = domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expires = cookie.expiresDate.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            output += "\(domain)\t\(includeSubdomains)\t\(cookiePath)\t\(secure)\t\(expires)\t\(cookie.name)\t\(cookie.value)\n"
        }

        do {
            try await context.filesystem.writeFile(
                path: context.resolvePath(path),
                data: Data(output.utf8),
                append: false
            )
            return .success(())
        } catch {
            context.writeStderr("curl: (\(path)) \(error)\n")
            return .failure(23)
        }
    }

    private static func parseNetscapeCookieLine(_ line: String, defaultHost: String) -> HTTPCookie? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("#"), !trimmed.hasPrefix("#HttpOnly_") {
            return nil
        }

        let httpOnly = trimmed.hasPrefix("#HttpOnly_")
        let content = httpOnly ? String(trimmed.dropFirst("#HttpOnly_".count)) : trimmed
        let fields = content.components(separatedBy: "\t")
        guard fields.count >= 7 else {
            return nil
        }

        let domain = fields[0].isEmpty ? defaultHost : fields[0]
        let path = fields[2].isEmpty ? "/" : fields[2]
        let secure = fields[3].uppercased() == "TRUE"
        let expires = TimeInterval(fields[4]) ?? 0
        let name = fields[5]
        let value = fields[6]

        guard !name.isEmpty else {
            return nil
        }

        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: domain,
            .path: path,
            .name: name,
            .value: value,
        ]
        if secure {
            properties[.secure] = "TRUE"
        }
        if expires > 0 {
            properties[.expires] = Date(timeIntervalSince1970: expires)
        }
        if httpOnly {
            properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
        }
        return HTTPCookie(properties: properties)
    }

    @discardableResult
    private static func emitError(
        _ context: inout CommandContext,
        options: Options,
        code: Int32,
        message: String
    ) -> Int32 {
        if !options.silent || options.showError {
            context.writeStderr(message)
        }
        return code
    }
}

struct WgetCommand: BuiltinCommand {
    struct Options: ParsableArguments {
        @Flag(name: [.long], help: "Display version information and exit")
        var version = false

        @Flag(name: [.short, .long], help: "Quiet mode")
        var quiet = false

        @Option(name: [.short, .customLong("output-document")], help: "Write documents to FILE")
        var outputDocument: String?

        @Option(name: [.customLong("user-agent")], help: "Set User-Agent")
        var userAgent: String?

        @Argument(help: "URL to fetch")
        var url: String?
    }

    static let name = "wget"
    static let overview = "Retrieve files from the web"

    static func _toAnyBuiltinCommand() -> AnyBuiltinCommand {
        AnyBuiltinCommand(
            name: name,
            aliases: aliases,
            overview: overview
        ) { context, args in
            let normalized = normalizeAttachedValueOptions(args)
            do {
                let options = try Options.parse(normalized)
                return await run(context: &context, options: options)
            } catch {
                let message = Options.fullMessage(for: error)
                if !message.isEmpty {
                    let output = message.hasSuffix("\n") ? message : message + "\n"
                    let exitCode = Options.exitCode(for: error).rawValue
                    if exitCode == 0 {
                        context.writeStdout(output)
                    } else {
                        context.writeStderr(output)
                    }
                }
                return Options.exitCode(for: error).rawValue
            }
        }
    }

    static func run(context: inout CommandContext, options: Options) async -> Int32 {
        if options.version {
            context.writeStdout("GNU Wget 1.24.5 (Bash.swift)\n")
            context.writeStdout("Built-in emulation command\n")
            return 0
        }

        guard let rawURL = options.url, !rawURL.isEmpty else {
            context.writeStderr("wget: missing URL\n")
            return 2
        }

        var argv: [String] = ["curl", "-L"]
        if options.quiet {
            argv.append("-s")
        }

        if let userAgent = options.userAgent, !userAgent.isEmpty {
            argv.append(contentsOf: ["-A", userAgent])
        }

        let outputTarget = options.outputDocument ?? defaultOutputFilename(for: rawURL)
        if outputTarget != "-" {
            argv.append(contentsOf: ["-o", outputTarget])
        }

        argv.append(rawURL)

        let subcommand = await context.runSubcommandIsolated(argv, stdin: Data())
        context.currentDirectory = subcommand.currentDirectory
        context.environment = subcommand.environment
        context.stdout.append(subcommand.result.stdout)
        context.stderr.append(subcommand.result.stderr)
        return subcommand.result.exitCode
    }

    private static let shortOptionsRequiringAttachedValue: Set<Character> = [
        "O",
    ]

    private static func normalizeAttachedValueOptions(_ args: [String]) -> [String] {
        var output: [String] = []
        var passthrough = false

        for arg in args {
            if passthrough {
                output.append(arg)
                continue
            }

            if arg == "--" {
                passthrough = true
                output.append(arg)
                continue
            }

            guard arg.hasPrefix("-"), !arg.hasPrefix("--"), arg.count > 2 else {
                output.append(arg)
                continue
            }

            let optionCharacter = arg[arg.index(after: arg.startIndex)]
            guard shortOptionsRequiringAttachedValue.contains(optionCharacter) else {
                output.append(arg)
                continue
            }

            let valueStart = arg.index(arg.startIndex, offsetBy: 2)
            let value = String(arg[valueStart...])
            guard !value.isEmpty else {
                output.append(arg)
                continue
            }

            output.append("-\(optionCharacter)")
            output.append(value)
        }

        return output
    }

    private static func defaultOutputFilename(for rawURL: String) -> String {
        let normalized: String
        if rawURL.hasPrefix("data:") || rawURL.hasPrefix("file:") || rawURL.contains("://") {
            normalized = rawURL
        } else {
            normalized = "https://\(rawURL)"
        }

        guard let url = URL(string: normalized) else {
            return "index.html"
        }

        let path = url.path
        if path.isEmpty || path.hasSuffix("/") {
            return "index.html"
        }

        let basename = PathUtils.basename(path)
        if basename.isEmpty || basename == "/" {
            return "index.html"
        }

        let decoded = basename.removingPercentEncoding ?? basename
        return decoded.isEmpty ? "index.html" : decoded
    }
}
