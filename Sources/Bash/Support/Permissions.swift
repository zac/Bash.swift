public struct PermissionRequest: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case network(NetworkPermissionRequest)
    }

    public var command: String
    public var kind: Kind

    public init(command: String, kind: Kind) {
        self.command = command
        self.kind = kind
    }
}

public struct NetworkPermissionRequest: Sendable, Hashable {
    public var url: String
    public var method: String

    public init(url: String, method: String) {
        self.url = url
        self.method = method
    }
}

public enum PermissionDecision: Sendable {
    case allow
    case allowForSession
    case deny(message: String?)
}

actor PermissionAuthorizer {
    typealias Handler = @Sendable (PermissionRequest) async -> PermissionDecision

    private let handler: Handler?
    private var sessionAllows: Set<PermissionRequest> = []

    init(handler: Handler? = nil) {
        self.handler = handler
    }

    func authorize(_ request: PermissionRequest) async -> PermissionDecision {
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
}
