import ReiCore
import SwiftUI

/// Renders one message segment.
struct SegmentView: View {
    let segment: MessageSegment
    let environment: AppEnvironment
    let chat: Chat
    var onReveal: ((Message.ID) -> Void)?
    var referenceContext: MessageReferenceContext?

    var body: some View {
        switch segment {
        case .text(let text):
            Text(text)

        case .mention(let userID):
            Text(userID == nil ? "@everyone" : "@\(environment.displayName(for: userID!, in: chat))")
                .foregroundStyle(.tint)

        case .face(_, let name):
            Text(name.map { "[\($0)]" } ?? "[Emoji]")
                .foregroundStyle(.secondary)

        case .image(let asset):
            ImageSegmentView(asset: asset, environment: environment)
                .id(asset.id)

        case .record(let asset, let duration):
            MediaSegmentView(asset: asset, environment: environment, duration: duration)
                .id(asset.id)

        case .video(let asset):
            MediaSegmentView(asset: asset, environment: environment, isVideo: true)
                .id(asset.id)

        case .file(let asset):
            FileSegmentView(asset: asset, environment: environment)
                .id(asset.id)

        case .reply(let messageID):
            QuotedMessageView(
                messageID: messageID, environment: environment, chat: chat, onReveal: onReveal,
                context: referenceContext ?? .conversation(chat)
            )

        case .poke:
            attachment(icon: "hand.point.right", label: "Poke")

        case .forward(_, let nodes):
            ForwardSegmentView(nodes: nodes, environment: environment, chat: chat)

        case .unsupported(let type, _):
            attachment(icon: "questionmark.square.dashed", label: "Unsupported message segment: \(type)")
        }
    }

    private func attachment(icon: String, label: String) -> some View {
        Label(label, systemImage: icon)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

}

/// The message a reply quotes.
struct QuotedMessageView: View {
    let messageID: String
    let environment: AppEnvironment
    let chat: Chat
    var onReveal: ((Message.ID) -> Void)?
    let context: MessageReferenceContext
    @State private var quoted: Message?
    @State private var isLoaded = false

    init(
        messageID: String, environment: AppEnvironment, chat: Chat, onReveal: ((Message.ID) -> Void)? = nil,
        context: MessageReferenceContext? = nil
    ) {
        self.messageID = messageID
        self.environment = environment
        self.chat = chat
        self.onReveal = onReveal
        self.context = context ?? .conversation(chat)
    }

    var body: some View {
        Group {
            if let onReveal, context.conversation != nil, quotePreview != nil {
                Button {
                    onReveal(messageID)
                } label: {
                    preview
                }
                .buttonStyle(.plain)
                .help("Jump to message")
            } else {
                preview
            }
        }
        .task(id: ObservationKey(messageID: messageID, context: context)) {
            isLoaded = false
            quoted = nil
            guard context.conversation != nil else {
                isLoaded = true
                return
            }
            do {
                for try await message in environment.store.observeMessage(id: messageID) {
                    quoted = message?.chat == chat ? message : nil
                    isLoaded = true
                }
            } catch is CancellationError {
                // The quote left the view hierarchy.
            } catch {
                isLoaded = true
                environment.lastError = error.localizedDescription
            }
        }
    }

    private var preview: some View {
        HStack(spacing: 6) {
            Rectangle().fill(.tint).frame(width: 2)
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    quotePreview.map { $0.senderName ?? environment.displayName(for: $0.senderID, in: chat) }
                        ?? "Quoted Message"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(
                    quotePreview?.text
                        ?? (isLoaded ? "Message unavailable" : "Loading message…")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
    }

    private var quotePreview: QuotedMessagePreview? {
        context.preview(for: messageID, message: quoted)
    }

    private struct ObservationKey: Hashable {
        var messageID: String
        var context: MessageReferenceContext
    }
}

/// Each bundle owns its disclosure state so nested forwards are opened on demand.
struct ForwardSegmentView: View {
    let nodes: [MessageSegment.ForwardNode]
    let environment: AppEnvironment
    let chat: Chat
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if nodes.isEmpty {
                Text("No forwarded messages are available.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(nodes.enumerated()), id: \.offset) { _, node in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(node.senderName).font(.callout.weight(.semibold))
                                Text(node.time, style: .date)
                                Text(node.time, style: .time)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(node.content.enumerated()), id: \.offset) { _, segment in
                                // Erase the type only at the recursive edge; otherwise
                                // the SwiftUI body type would contain itself.
                                AnyView(
                                    SegmentView(
                                        segment: segment, environment: environment, chat: chat,
                                        referenceContext: .forwarded(nodes)
                                    )
                                )
                            }
                        }
                        .textSelection(.enabled)
                    }
                }
                .padding(.top, 6)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label("Forwarded Messages · \(nodes.count)", systemImage: "rectangle.stack")
                    .font(.callout)
                if !isExpanded {
                    ForEach(Array(nodes.prefix(3).enumerated()), id: \.offset) { _, node in
                        Text("\(node.senderName): \(node.content.textPreview)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(8)
        .background(.quinary, in: .rect(cornerRadius: 6))
    }
}
