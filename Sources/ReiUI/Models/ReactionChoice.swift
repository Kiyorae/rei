import ReiCore

/// Small, stable choices from QQ's face namespace. Their Unicode counterparts
/// are presentation only; the platform receives the original face identifier.
struct ReactionChoice: Identifiable {
    let reaction: Reaction
    let symbol: String
    let name: String

    var id: Reaction { reaction }

    static let common: [ReactionChoice] = [
        .init(reaction: Reaction(kind: .face, value: "76"), symbol: "👍", name: "Like"),
        .init(reaction: Reaction(kind: .face, value: "66"), symbol: "❤️", name: "Heart"),
        .init(reaction: Reaction(kind: .face, value: "14"), symbol: "🙂", name: "Smile"),
        .init(reaction: Reaction(kind: .face, value: "28"), symbol: "😄", name: "Grin"),
        .init(reaction: Reaction(kind: .face, value: "99"), symbol: "👏", name: "Applause"),
        .init(reaction: Reaction(kind: .face, value: "77"), symbol: "👎", name: "Dislike"),
    ]

    static func label(for reaction: Reaction) -> String {
        if let choice = common.first(where: { $0.reaction == reaction }) { return choice.symbol }
        if reaction.kind == .emoji,
            let value = UInt32(reaction.value), let scalar = Unicode.Scalar(value), scalar.properties.isEmoji
        {
            return String(scalar)
        }
        return "\(reaction.kind == .face ? "Face" : "Emoji") \(reaction.value)"
    }
}
