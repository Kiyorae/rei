import ReiCore
import SwiftUI

/// A chat owns one stable transcript. Appends animate at the bottom; browsing
/// history records the user's intent instead of chasing every content-size change.
struct ChatTranscript: View {
    let environment: AppEnvironment
    let chat: Chat
    let reply: (Message) -> Void
    let reveal: (Message.ID) -> Void
    let clearHistory: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsLatest = true
    @State private var isNearBottom = true
    @State private var isUserScrolling = false
    @State private var hasNewMessages = false

    private var messageIDs: [Message.ID] { environment.messages.map(\.id) }
    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(environment.messages) { message in
                        MessageRow(
                            message: message, chat: chat, environment: environment,
                            onReply: { reply(message) }, onReveal: reveal
                        )
                        .id(message.id)
                        // Scrolling supplies the movement for every row; an extra
                        // move transition would give incoming rows a second velocity.
                        .transition(reduceMotion ? .identity : .opacity)
                    }
                }
                .frame(maxWidth: 920)
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .defaultScrollAnchor(
                followsLatest ? .bottom : nil, for: .sizeChanges
            )
            .animation(animation, value: messageIDs)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 32
            } action: { _, nearBottom in
                isNearBottom = nearBottom
                if isUserScrolling {
                    followsLatest = nearBottom
                    if nearBottom { hasNewMessages = false }
                }
            }
            .onScrollPhaseChange { oldPhase, phase in
                isUserScrolling = phase == .interacting || phase == .decelerating
                if phase == .idle, oldPhase == .interacting || oldPhase == .decelerating {
                    followsLatest = isNearBottom
                    if isNearBottom { hasNewMessages = false }
                }
            }
            .onChange(of: messageIDs) { oldIDs, ids in
                guard let newest = ids.last, newest != oldIDs.last else { return }
                guard followsLatest else {
                    hasNewMessages = true
                    return
                }
                withAnimation(animation) { proxy.scrollTo(newest, anchor: .bottom) }
            }
            .onChange(of: environment.messageReveal) { _, request in
                guard let request, request.chat == chat else { return }
                followsLatest = false
                withAnimation(animation) { proxy.scrollTo(request.messageID, anchor: .center) }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasNewMessages {
                    Button("Jump to Latest", systemImage: "arrow.down") {
                        guard let newest = messageIDs.last else { return }
                        followsLatest = true
                        hasNewMessages = false
                        withAnimation(animation) { proxy.scrollTo(newest, anchor: .bottom) }
                    }
                    .buttonStyle(.glass)
                    .padding(16)
                }
            }
            .contextMenu {
                Button("Clear Chat History…", systemImage: "trash", role: .destructive, action: clearHistory)
            }
        }
    }
}
