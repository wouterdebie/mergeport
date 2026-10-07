import Foundation

public enum PRGrouping: String, Codable, CaseIterable, Sendable {
    case repository, branch, branchGroups, ticket, none
    public var title: String {
        switch self {
        case .repository: "Repository"
        case .branch: "Source branch"
        case .branchGroups: "Branch groups"
        case .ticket: "Ticket identifier"
        case .none: "No grouping"
        }
    }
}

public struct BranchIdentity: Codable, Hashable, Sendable {
    public let repository: String
    public let sourceRepository: String
    public let branch: String
    public var id: String { "\(repository)|\(sourceRepository)|\(branch)" }

    public init(repository: String, sourceRepository: String, branch: String) {
        self.repository = repository.lowercased()
        self.sourceRepository = sourceRepository.lowercased()
        self.branch = branch
    }

    public init(_ pr: PullRequest) {
        self.init(repository: pr.repository, sourceRepository: pr.headRepository, branch: pr.head)
    }

    public func withBranch(_ branch: String) -> BranchIdentity {
        BranchIdentity(repository: repository, sourceRepository: sourceRepository, branch: branch)
    }
}

public struct BranchAlias: Codable, Identifiable, Equatable, Sendable {
    public let source: BranchIdentity
    public let target: String
    public var id: String { source.id }
}

public struct PullRequestGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbol: String
    public var pullRequests: [PullRequest]
    public let isUnmatched: Bool
}

public struct GroupingPreferences: Codable, Equatable, Sendable {
    public var mode: PRGrouping = .repository
    public var ticketPrefixes = ["CON-"]
    public var branchSuffixes = ["-staging", "-test"]
    public var aliases: [BranchAlias] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case mode, ticketPrefixes, branchSuffixes, aliases }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        mode = try fields.decode(PRGrouping.self, forKey: .mode)
        ticketPrefixes = try fields.decode([String].self, forKey: .ticketPrefixes)
        aliases = try fields.decode([BranchAlias].self, forKey: .aliases)
        branchSuffixes = try fields.decodeIfPresent([String].self, forKey: .branchSuffixes) ?? ["-staging", "-test"]
    }

    public static func suffixes(from input: String) throws -> [String] {
        var result: [String] = []
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for part in input.components(separatedBy: ",") {
            var suffix = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if suffix.isEmpty { continue }
            if !suffix.hasPrefix("-") { suffix = "-" + suffix }
            guard suffix.count > 1, suffix.unicodeScalars.allSatisfy(allowed.contains) else {
                throw MergeportError.message("Branch suffixes must contain letters, digits, underscores or hyphens, for example -staging, -test.")
            }
            if !result.contains(suffix) { result.append(suffix) }
        }
        return result
    }

    public func normalizedBranch(_ branch: String) -> String {
        let suffixes = branchSuffixes.sorted { $0.count > $1.count }
        var name = branch
        while let suffix = suffixes.first(where: { !$0.isEmpty && name.count > $0.count && name.hasSuffix($0) }) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    public static func prefixes(from input: String) throws -> [String] {
        var result: [String] = []
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for part in input.components(separatedBy: ",") {
            var value = part.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if value.isEmpty { continue }
            if !value.hasSuffix("-") { value += "-" }
            guard value.first?.isASCII == true, value.first?.isLetter == true,
                  value.unicodeScalars.allSatisfy(allowed.contains) else {
                throw MergeportError.message("Ticket prefixes must start with a letter and contain only letters, digits, underscores or hyphens. For example CON-, ENG-.")
            }
            if !result.contains(value) { result.append(value) }
        }
        guard !result.isEmpty else { throw MergeportError.message("Enter at least one ticket prefix, such as CON-.") }
        return result
    }

    public func validate() throws {
        guard ticketPrefixes == (try Self.prefixes(from: ticketPrefixes.joined(separator: ","))) else {
            throw MergeportError.message("Ticket prefixes must be normalized and unique.")
        }
        guard branchSuffixes == (try Self.suffixes(from: branchSuffixes.joined(separator: ","))) else {
            throw MergeportError.message("Branch suffixes must be normalized and unique.")
        }
        guard Set(aliases.map(\.source)).count == aliases.count else { throw MergeportError.message("A branch has duplicate group aliases.") }
        for alias in aliases {
            guard !alias.source.branch.isEmpty, !alias.target.isEmpty, alias.source.branch != alias.target else {
                throw MergeportError.message("A branch alias must point to a different, nonempty source branch.")
            }
            _ = try canonicalBranch(alias.source)
        }
    }

    public func canonicalBranch(_ identity: BranchIdentity) throws -> String {
        var current = identity
        var visited: Set<BranchIdentity> = []
        while let alias = aliases.first(where: { $0.source == current }) {
            guard visited.insert(current).inserted else { throw MergeportError.message("Branch group aliases cannot form a cycle.") }
            current = current.withBranch(alias.target)
        }
        return current.branch
    }

    public mutating func addAlias(source: BranchIdentity, target: String) throws {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw MergeportError.message("Choose the source branch to group with.") }
        guard target != source.branch else { throw MergeportError.message("A branch cannot be grouped with itself.") }
        let canonical = try canonicalBranch(source.withBranch(target))
        guard canonical != source.branch else { throw MergeportError.message("A branch cannot be grouped with itself or form a cycle.") }
        var updated = self
        updated.aliases.removeAll { $0.source == source }
        updated.aliases.append(BranchAlias(source: source, target: canonical))
        try updated.validate()
        self = updated
    }

    public func sameBranchFamily(_ lhs: PullRequest, _ rhs: PullRequest) throws -> Bool {
        let left = BranchIdentity(lhs), right = BranchIdentity(rhs)
        guard lhs.number != rhs.number, left.repository == right.repository, left.sourceRepository == right.sourceRepository else { return false }
        let leftBranch = try canonicalBranch(left), rightBranch = try canonicalBranch(right)
        return mode == .branchGroups ? normalizedBranch(leftBranch) == normalizedBranch(rightBranch) : leftBranch == rightBranch
    }

    public func ticketIdentifier(for pr: PullRequest) throws -> String? {
        try ticketIdentifier(for: pr, matcher: ticketMatcher())
    }

    private func ticketMatcher() throws -> NSRegularExpression {
        let prefixes = try Self.prefixes(from: ticketPrefixes.joined(separator: ","))
        let choices = prefixes.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try NSRegularExpression(pattern: "(?<![A-Z0-9])(?:\(choices))[0-9]+(?![A-Z0-9])", options: .caseInsensitive)
    }

    private func ticketIdentifier(for pr: PullRequest, matcher: NSRegularExpression) throws -> String? {
        let canonical = try canonicalBranch(BranchIdentity(pr))
        for text in [canonical, pr.head, pr.title] {
            if let match = matcher.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) { return String(text[range]).uppercased() }
        }
        return nil
    }

    public func groups(for pullRequests: [PullRequest]) throws -> [PullRequestGroup] {
        try validate()
        let matcher = try ticketMatcher()
        var groups: [String: PullRequestGroup] = [:]
        for pr in pullRequests.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let id: String, title: String, symbol: String
            let subtitle: String?
            let unmatched: Bool
            switch mode {
            case .repository:
                id = "repo:\(pr.repository.lowercased())"; title = pr.repository; subtitle = nil; symbol = "shippingbox"; unmatched = false
            case .branch, .branchGroups:
                let identity = BranchIdentity(pr)
                let canonical = try canonicalBranch(identity)
                let branch = mode == .branchGroups ? normalizedBranch(canonical) : canonical
                id = "branch:\(identity.withBranch(branch).id)"; title = branch
                subtitle = pr.headRepository == pr.repository ? pr.repository : "\(pr.repository) · source: \(pr.headRepository)"
                symbol = "arrow.triangle.branch"; unmatched = false
            case .ticket:
                let ticket = try ticketIdentifier(for: pr, matcher: matcher)
                id = ticket.map { "ticket:\($0)" } ?? "ticket:unmatched"
                title = ticket ?? "No ticket identifier"; subtitle = nil; symbol = "number"; unmatched = ticket == nil
            case .none:
                id = "all"; title = ""; subtitle = nil; symbol = "tray"; unmatched = false
            }
            if groups[id] != nil { groups[id]?.pullRequests.append(pr) }
            else { groups[id] = PullRequestGroup(id: id, title: title, subtitle: subtitle, symbol: symbol, pullRequests: [pr], isUnmatched: unmatched) }
        }
        // Groups surface recent activity first; cards inside a group read by repository and number.
        return groups.values.map {
            var group = $0
            group.pullRequests.sort(by: PullRequest.overviewOrder)
            return group
        }.sorted {
            if $0.isUnmatched != $1.isUnmatched { return !$0.isUnmatched }
            if mode == .repository { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            let left = $0.pullRequests.map(\.updatedAt).max() ?? .distantPast
            let right = $1.pullRequests.map(\.updatedAt).max() ?? .distantPast
            return left == right ? $0.id < $1.id : left > right
        }
    }
}

extension PullRequest {
    /// Overview card order: repository (case-insensitive), then PR number.
    public static func overviewOrder(_ lhs: PullRequest, _ rhs: PullRequest) -> Bool {
        switch lhs.repository.compare(rhs.repository, options: [.caseInsensitive, .numeric]) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.number < rhs.number
        }
    }
}
