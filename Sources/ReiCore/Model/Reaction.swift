import Foundation

/// An opaque platform expression ID. Face IDs and Unicode emoji IDs occupy
/// different namespaces, even when their serialized values happen to match.
public struct Reaction: Hashable, Sendable, Codable {
    public enum Kind: String, CaseIterable, Sendable, Codable {
        case face
        case emoji
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// The people currently using one reaction on a message. Counts are derived
/// from membership so retries cannot inflate them.
public struct MessageReaction: Hashable, Sendable, Codable, Identifiable {
    public var reaction: Reaction
    public var userIDs: Set<String>

    public var id: Reaction { reaction }

    public init(reaction: Reaction, userIDs: Set<String>) {
        self.reaction = reaction
        self.userIDs = userIDs
    }
}
