import ReiCore
import SwiftUI

enum ConversationInspectorSection: String, Identifiable, CaseIterable {
    case overview = "Overview"
    case members = "Members"
    case files = "Files"
    case announcements = "Announcements"
    case highlights = "Highlights"
    case settings = "Settings"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .members: "person.2"
        case .files: "folder"
        case .announcements: "megaphone"
        case .highlights: "star"
        case .settings: "slider.horizontal.3"
        }
    }

    static func available(capabilities: ConversationContentCapabilities, supportsSettings: Bool) -> [Self] {
        var sections: [Self] = [.overview]
        if capabilities.scene == .group { sections.append(.members) }
        if capabilities.supportsFiles { sections.append(.files) }
        if capabilities.supportsGroupContent { sections += [.announcements, .highlights] }
        if supportsSettings { sections.append(.settings) }
        return sections
    }
}

/// Chat identity owns the model lifetime; switching recipients cannot retain an
/// editor, folder selection, or pending confirmation from the previous chat.
struct ConversationInspectorView: View {
    @State private var model: ConversationContentModel
    @Binding var section: ConversationInspectorSection

    init(environment: AppEnvironment, chat: Chat, section: Binding<ConversationInspectorSection>) {
        _model = State(initialValue: ConversationContentModel(environment: environment, chat: chat))
        _section = section
    }

    private var sections: [ConversationInspectorSection] {
        ConversationInspectorSection.available(
            capabilities: model.capabilities,
            supportsSettings: model.environment.supportsGroupProfiles || model.environment.supportsRequestEvents
        )
    }

    private var visibleSection: ConversationInspectorSection { sections.contains(section) ? section : .overview }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.environment.conversationTitle(for: model.chat))
                    .font(.callout.weight(.medium)).lineLimit(1)
                Spacer(minLength: 8)
                Menu {
                    Picker("Conversation Section", selection: $section) {
                        ForEach(sections) { item in
                            Label(item.rawValue, systemImage: item.symbol).tag(item)
                        }
                    }
                } label: {
                    Label(visibleSection.rawValue, systemImage: visibleSection.symbol)
                        .font(.callout)
                }
                .fixedSize()
                .help("Choose conversation details")
                if model.isWorking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            Divider()
            Group {
                switch visibleSection {
                case .overview: ConversationOverviewView(model: model)
                case .members: GroupMembersView(environment: model.environment, groupID: model.chat.peerID)
                case .files: ConversationFilesView(model: model)
                case .announcements: ConversationAnnouncementsView(model: model)
                case .highlights: ConversationHighlightsView(model: model, didReveal: {})
                case .settings: ConversationManagementView(environment: model.environment, chat: model.chat)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(model.isWorking)
            if model.errorMessage != nil {
                Divider()
                ConversationContentError(model: model).padding(12)
            }
        }
        .task { if model.chat.scene == .group { await model.environment.loadMembers(groupID: model.chat.peerID) } }
        .task { await model.observeState() }
        .task { await model.observeMessages() }
        .onChange(of: sections, initial: true) { _, options in
            if !options.contains(section) { section = .overview }
        }
    }
}
