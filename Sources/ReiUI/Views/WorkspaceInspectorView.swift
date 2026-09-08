import SwiftUI

enum WorkspaceInspectorTab: String, CaseIterable, Identifiable {
    case conversation = "Conversation"
    case events = "Events"

    var id: String { rawValue }
    var symbol: String { self == .conversation ? "bubble.left" : "curlybraces" }
}

/// One inspector owns its chrome; feature views only supply the content below it.
struct WorkspaceInspectorView: View {
    let environment: AppEnvironment
    @Binding var tab: WorkspaceInspectorTab
    @Binding var section: ConversationInspectorSection
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Picker("Inspector", selection: $tab) {
                    ForEach(WorkspaceInspectorTab.allCases) { item in
                        Label(item.rawValue, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.large)
                Spacer(minLength: 4)
                Button("Close Inspector", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide Inspector (⌥⌘I)")
            }
            .padding(.horizontal, 12)
            .frame(height: 52)
            Divider()
            // Keeping the traffic view mounted preserves selection and filters
            // while a conversation tool is in use.
            ZStack {
                TrafficInspectorView(environment: environment)
                    .opacity(tab == .events ? 1 : 0)
                    .allowsHitTesting(tab == .events)
                    .accessibilityHidden(tab != .events)
                Group {
                    if let chat = environment.selectedChat {
                        ConversationInspectorView(environment: environment, chat: chat, section: $section)
                            .id(chat)
                    } else {
                        ContentUnavailableView(
                            "Conversation Details", systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Select a conversation to see its members, shared content, and settings.")
                        )
                    }
                }
                .opacity(tab == .conversation ? 1 : 0)
                .allowsHitTesting(tab == .conversation)
                .accessibilityHidden(tab != .conversation)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
