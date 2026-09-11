import ReiCore

public enum ReiSettingsTab: Hashable, Sendable {
    case connection
    case roles
    case about
}

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

enum UserSelectionPurpose: Equatable {
    case friend
    case group(ReiCore.Group.ID)
}

enum ConversationRequestKind: String, Identifiable {
    case friend, joinGroup, inviteBot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .friend: return "Send Friend Request"
        case .joinGroup: return "Request to Join Group"
        case .inviteBot: return "Invite Bot to Group"
        }
    }
}
