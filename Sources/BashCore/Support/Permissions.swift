import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ShellPermissionRequest: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case network(ShellNetworkPermissionRequest)
        case filesystem(ShellFilesystemPermissionRequest)
    }

    public var command: String
    public var kind: Kind

    public init(command: String, kind: Kind) {
        self.command = command
        self.kind = kind
    }
}

public struct ShellNetworkPermissionRequest: Sendable, Hashable {
    public var url: String
    public var method: String

    public init(url: String, method: String) {
        self.url = url
        self.method = method
    }
}

public enum ShellFilesystemPermissionOperation: String, Sendable, Hashable {
    case stat
    case listDirectory
    case readFile
    case writeFile
    case createDirectory
    case remove
    case move
    case copy
    case createSymlink
    case createHardLink
    case readSymlink
    case setPermissions
    case resolveRealPath
    case exists
    case glob
}

public struct ShellFilesystemPermissionRequest: Sendable, Hashable {
    public var operation: ShellFilesystemPermissionOperation
    public var path: String?
    public var sourcePath: String?
    public var destinationPath: String?
    public var append: Bool
    public var recursive: Bool

    public init(
        operation: ShellFilesystemPermissionOperation,
        path: String? = nil,
        sourcePath: String? = nil,
        destinationPath: String? = nil,
        append: Bool = false,
        recursive: Bool = false
    ) {
        self.operation = operation
        self.path = path
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.append = append
        self.recursive = recursive
    }
}

public struct ShellNetworkPolicy: Sendable {
    public static let disabled = ShellNetworkPolicy()
    public static let unrestricted = ShellNetworkPolicy(allowsHTTPRequests: true)

    public var allowsHTTPRequests: Bool
    public var allowedHosts: [String]
    public var allowedURLPrefixes: [String]
    public var denyPrivateRanges: Bool

    public init(
        allowsHTTPRequests: Bool = false,
        allowedHosts: [String] = [],
        allowedURLPrefixes: [String] = [],
        denyPrivateRanges: Bool = false
    ) {
        self.allowsHTTPRequests = allowsHTTPRequests
        self.allowedHosts = allowedHosts
        self.allowedURLPrefixes = allowedURLPrefixes
        self.denyPrivateRanges = denyPrivateRanges
    }

    var hasAllowlist: Bool {
        !allowedHosts.isEmpty || !allowedURLPrefixes.isEmpty
    }
}

public enum ShellPermissionDecision: Sendable {
    case allow
    case allowForSession
    case deny(message: String?)
}

public protocol ShellPermissionAuthorizing: Sendable {
    func authorize(_ request: ShellPermissionRequest) async -> ShellPermissionDecision
}

package actor ShellPermissionAuthorizer: ShellPermissionAuthorizing {
    package typealias Handler = @Sendable (ShellPermissionRequest) async -> ShellPermissionDecision

    private let networkPolicy: ShellNetworkPolicy
    private let handler: Handler?
    private var sessionAllows: Set<ShellPermissionRequest> = []

    package init(
        networkPolicy: ShellNetworkPolicy = .disabled,
        handler: Handler? = nil
    ) {
        self.networkPolicy = networkPolicy
        self.handler = handler
    }

    package func authorize(_ request: ShellPermissionRequest) async -> ShellPermissionDecision {
        if let denial = PermissionPolicyEvaluator.denialMessage(
            for: request,
            networkPolicy: networkPolicy
        ) {
            return .deny(message: denial)
        }

        if sessionAllows.contains(request) {
            return .allow
        }

        guard let handler else {
            return .allow
        }

        let decision = await handler(request)
        if case .allowForSession = decision {
            sessionAllows.insert(request)
            return .allow
        }

        return decision
    }

    package func authorize(
        _ request: ShellPermissionRequest,
        pausing executionControl: ExecutionControl?
    ) async -> ShellPermissionDecision {
        if let denial = PermissionPolicyEvaluator.denialMessage(
            for: request,
            networkPolicy: networkPolicy
        ) {
            return .deny(message: denial)
        }

        if sessionAllows.contains(request) {
            return .allow
        }

        guard let handler else {
            return .allow
        }

        if let executionControl {
            await executionControl.beginPermissionPause()
        }

        let decision = await handler(request)

        if let executionControl {
            await executionControl.endPermissionPause()
        }

        if case .allowForSession = decision {
            sessionAllows.insert(request)
            return .allow
        }

        return decision
    }
}

func authorizePermissionRequest(
    _ request: ShellPermissionRequest,
    using authorizer: any ShellPermissionAuthorizing,
    pausing executionControl: ExecutionControl?
) async -> ShellPermissionDecision {
    if let authorizer = authorizer as? ShellPermissionAuthorizer {
        return await authorizer.authorize(request, pausing: executionControl)
    }

    if let executionControl {
        await executionControl.beginPermissionPause()
    }

    let decision = await authorizer.authorize(request)

    if let executionControl {
        await executionControl.endPermissionPause()
    }

    return decision
}

private enum PermissionPolicyEvaluator {
    static func denialMessage(
        for request: ShellPermissionRequest,
        networkPolicy: ShellNetworkPolicy
    ) -> String? {
        switch request.kind {
        case let .network(networkRequest):
            denialMessage(for: networkRequest, networkPolicy: networkPolicy)
        case .filesystem:
            nil
        }
    }

    private static func denialMessage(
        for request: ShellNetworkPermissionRequest,
        networkPolicy: ShellNetworkPolicy
    ) -> String? {
        guard networkPolicy.allowsHTTPRequests else {
            return "network access denied by policy: outbound HTTP(S) access is disabled"
        }

        let host = parsedHost(from: request.url)

        if networkPolicy.hasAllowlist {
            let prefixAllowed = networkPolicy.allowedURLPrefixes.contains {
                urlMatchesPrefix(request.url, allowedPrefix: $0)
            }
            let hostAllowed = if let host {
                hostIsAllowed(host, allowedHosts: networkPolicy.allowedHosts)
            } else {
                false
            }

            guard prefixAllowed || hostAllowed else {
                return "network access denied by policy: '\(request.url)' is not in the network allowlist"
            }
        }

        if networkPolicy.denyPrivateRanges,
           let host,
           hostTargetsPrivateRange(host) {
            return "network access denied by policy: private network host '\(host)'"
        }

        return nil
    }

    private static func parsedHost(from urlString: String) -> String? {
        URL(string: urlString)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func hostIsAllowed(_ host: String, allowedHosts: [String]) -> Bool {
        let normalized = host.lowercased()
        for candidate in allowedHosts {
            let allowed = candidate.lowercased()
            if normalized == allowed || normalized.hasSuffix(".\(allowed)") {
                return true
            }
        }
        return false
    }

    private static func urlMatchesPrefix(_ urlString: String, allowedPrefix: String) -> Bool {
        guard
            let request = URLComponents(string: urlString),
            let allowed = URLComponents(string: allowedPrefix),
            let requestScheme = request.scheme?.lowercased(),
            let allowedScheme = allowed.scheme?.lowercased(),
            let requestHost = request.host?.lowercased(),
            let allowedHost = allowed.host?.lowercased()
        else {
            return false
        }

        guard requestScheme == allowedScheme, requestHost == allowedHost else {
            return false
        }

        if effectivePort(for: request) != effectivePort(for: allowed) {
            return false
        }

        let allowedPath = normalizedPrefixPath(allowed.path)
        let requestPath = normalizedPrefixPath(request.path)
        if allowedPath != "/", hasAmbiguousEncodedSeparator(in: request.percentEncodedPath) {
            return false
        }

        if allowedPath == "/" {
            return true
        }

        if allowedPath.hasSuffix("/") {
            return requestPath.hasPrefix(allowedPath)
        }

        return requestPath == allowedPath || requestPath.hasPrefix(allowedPath + "/")
    }

    private static func normalizedPrefixPath(_ path: String) -> String {
        path.isEmpty ? "/" : path
    }

    private static func effectivePort(for components: URLComponents) -> Int? {
        if let port = components.port {
            return port
        }

        switch components.scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    private static func hasAmbiguousEncodedSeparator(in percentEncodedPath: String) -> Bool {
        let lower = percentEncodedPath.lowercased()
        return lower.contains("%2f") || lower.contains("%5c")
    }

    private static func hostTargetsPrivateRange(_ host: String) -> Bool {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if normalized == "localhost"
            || normalized == "localhost."
            || normalized.hasSuffix(".localhost")
            || normalized.hasSuffix(".localhost.") {
            return true
        }

        if normalized.hasSuffix(".local") || normalized.hasSuffix(".home.arpa") {
            return true
        }

        if let ipv4 = parseIPv4Address(normalized) {
            return isPrivateIPv4(ipv4)
        }

        if let ipv6 = parseIPv6Address(normalized) {
            return isPrivateIPv6(ipv6)
        }

        for address in resolvedAddresses(for: normalized) {
            switch address {
            case let .ipv4(octets):
                if isPrivateIPv4(octets) {
                    return true
                }
            case let .ipv6(bytes):
                if isPrivateIPv6(bytes) {
                    return true
                }
            }
        }

        return false
    }

    private enum ResolvedAddress {
        case ipv4([UInt8])
        case ipv6([UInt8])
    }

    private static func parseIPv4Address(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }

        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard let value = UInt8(part) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func parseIPv6Address(_ host: String) -> [UInt8]? {
        var storage = in6_addr()
        let result = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &storage)
        }
        guard result == 1 else {
            return nil
        }
        return withUnsafeBytes(of: storage) { Array($0) }
    }

    private static func resolvedAddresses(for host: String) -> [ResolvedAddress] {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )

        var results: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { pointer in
            getaddrinfo(pointer, nil, &hints, &results)
        }
        guard status == 0, let results else {
            return []
        }
        defer { freeaddrinfo(results) }

        var addresses: [ResolvedAddress] = []
        var current: UnsafeMutablePointer<addrinfo>? = results
        while let entry = current {
            let info = entry.pointee
            if info.ai_family == AF_INET, let addr = info.ai_addr {
                let value = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    $0.pointee.sin_addr
                }
                let octets = withUnsafeBytes(of: value.s_addr.bigEndian) { Array($0) }
                addresses.append(.ipv4(octets))
            } else if info.ai_family == AF_INET6, let addr = info.ai_addr {
                let value = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr
                }
                let bytes = withUnsafeBytes(of: value) { Array($0) }
                addresses.append(.ipv6(bytes))
            }
            current = info.ai_next
        }

        return addresses
    }

    private static func isPrivateIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else {
            return false
        }

        switch (octets[0], octets[1]) {
        case (0, _):
            return true
        case (10, _):
            return true
        case (100, 64...127):
            return true
        case (127, _):
            return true
        case (169, 254):
            return true
        case (172, 16...31):
            return true
        case (192, 168):
            return true
        default:
            return false
        }
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else {
            return false
        }

        if bytes[0...14].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return true
        }

        if bytes[0] == 0xfc || bytes[0] == 0xfd {
            return true
        }

        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 {
            return true
        }

        if bytes[0...9].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isPrivateIPv4(Array(bytes[12...15]))
        }

        return false
    }
}
