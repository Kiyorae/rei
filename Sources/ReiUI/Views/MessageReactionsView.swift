import ReiCore
import SwiftUI

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

struct ReactionPicker: View {
    let onSelect: (Reaction) -> Void
    @State private var query = ""
    @State private var kind: Reaction.Kind = .face
    @State private var identifier = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Reaction").font(.headline)
            TextField("Find a reaction", text: $query)
                .textFieldStyle(.roundedBorder)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 8) {
                ForEach(
                    ReactionChoice.common.filter {
                        query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
                    }
                ) { choice in
                    Button {
                        onSelect(choice.reaction)
                    } label: {
                        Text(choice.symbol).font(.title2).frame(width: 48, height: 36)
                    }
                    .buttonStyle(.borderless)
                    .help(choice.name)
                    .accessibilityLabel(choice.name)
                }
            }
            DisclosureGroup("Other Expression") {
                VStack(spacing: 8) {
                    Picker("Type", selection: $kind) {
                        Text("QQ Face").tag(Reaction.Kind.face)
                        Text("Emoji").tag(Reaction.Kind.emoji)
                    }
                    TextField("Expression ID", text: $identifier)
                    Button("Add") {
                        onSelect(
                            Reaction(kind: kind, value: identifier.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                    .disabled(identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(width: 270)
    }
}

struct MessageReactionsView: View {
    let message: Message
    let environment: AppEnvironment
    @State private var pending: Set<Reaction> = []

    var body: some View {
        ViewThatFits(in: .horizontal) {
            reactions
            ScrollView(.horizontal) { reactions }.scrollIndicators(.hidden)
        }
    }

    private var reactions: some View {
        HStack(spacing: 4) {
            ForEach(message.reactions) { item in
                let selected = environment.activeUserID.map(item.userIDs.contains) ?? false
                Button {
                    guard pending.insert(item.reaction).inserted else { return }
                    Task {
                        await environment.setReaction(item.reaction, on: message, added: !selected)
                        pending.remove(item.reaction)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(ReactionChoice.label(for: item.reaction))
                        Text(item.userIDs.count, format: .number).monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary), in: .capsule
                    )
                    .overlay { Capsule().stroke(selected ? Color.accentColor : .clear, lineWidth: 1) }
                }
                .buttonStyle(.plain)
                .disabled(!environment.canInteract(in: message.chat) || pending.contains(item.reaction))
                .help(
                    item.userIDs.sorted().map { environment.displayName(for: $0, in: message.chat) }.joined(
                        separator: ", ")
                )
                .accessibilityLabel("\(ReactionChoice.label(for: item.reaction)), \(item.userIDs.count) reactions")
                .accessibilityValue(selected ? "Reacted" : "Not reacted")
            }
        }
    }
}
