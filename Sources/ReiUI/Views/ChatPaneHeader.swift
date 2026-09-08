import ReiCore
import SwiftUI

/// Conversation chrome belongs to its pane, so it stays aligned when either
/// sidebar is resized or collapsed.
struct ChatPaneHeader: View {
    let environment: AppEnvironment
    let inspect: (Chat, ConversationInspectorSection) -> Void
    let showingInspector: Bool
    let toggleInspector: () -> Void
    @State private var nudgeSent = false

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                if let chat = environment.selectedChat {
                    Image(systemName: chat.scene == .group ? "person.3" : "bubble.left")
                        .foregroundStyle(.secondary)
                    Text(environment.conversationTitle(for: chat))
                        .font(.headline).lineLimit(1)
                        .help(environment.conversationTitle(for: chat))
                    Spacer(minLength: 8)
                    if chat.scene == .group {
                        Button("Group Members", systemImage: "person.2") { inspect(chat, .members) }
                            .help("Show group members in the inspector")
                    } else if environment.supportsNudges(in: chat),
                        let activeUserID = environment.activeUserID,
                        let peerID = chat.counterpartID(for: activeUserID)
                    {
                        Button(nudgeSent ? "Nudge Sent" : "Nudge", systemImage: "hand.point.right") {
                            Task {
                                nudgeSent = await environment.nudge(peerID, in: chat)
                                try? await Task.sleep(for: .seconds(2))
                                nudgeSent = false
                            }
                        }
                        .disabled(nudgeSent || !environment.canInteract(in: chat))
                        .help("Nudge \(environment.displayName(for: peerID, in: chat))")
                    }
                } else {
                    Text("Conversations").font(.headline)
                    Spacer()
                }
                Button(
                    showingInspector ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing",
                    action: toggleInspector
                )
                .help(showingInspector ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }
}
