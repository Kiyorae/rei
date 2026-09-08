import ReiCore

/// Forward nodes carry no original conversation identity. Their references can
/// only resolve to nodes in the same bundle, never to the live transcript store.
enum MessageReferenceContext: Hashable, Sendable {
    case conversation(Chat)
    case forwarded([MessageSegment.ForwardNode])

    var conversation: Chat? {
        if case .conversation(let chat) = self { return chat }
        return nil
    }

    func preview(for messageID: String, message: Message?) -> QuotedMessagePreview? {
        switch self {
        case .conversation(let chat):
            guard let message, message.id == messageID, message.chat == chat else { return nil }
            return QuotedMessagePreview(
                senderID: message.senderID,
                senderName: nil,
                text: message.isRecalled ? "Message recalled" : message.content.textPreview
            )
        case .forwarded(let nodes):
            guard let node = nodes.first(where: { $0.id == messageID }) else { return nil }
            return QuotedMessagePreview(
                senderID: node.senderID, senderName: node.senderName, text: node.content.textPreview)
        }
    }
}

struct QuotedMessagePreview {
    var senderID: String
    var senderName: String?
    var text: String
}
