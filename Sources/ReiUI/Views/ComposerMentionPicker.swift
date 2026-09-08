import ReiCore
import SwiftUI

struct ComposerMentionPicker: View {
    let environment: AppEnvironment
    let chat: Chat
    @Binding var draft: ComposerDraft
    let didSelect: () -> Void
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mention a Member").font(.headline)
            NativeSearchField(text: $query, prompt: "Search members", accessibilityLabel: "Search members to mention")
                .frame(height: 28)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if query.isEmpty || "everyone".localizedCaseInsensitiveContains(query) {
                        entry(name: "Everyone", detail: "Notify all members", userID: nil)
                        Divider()
                    }
                    ForEach(matchingMembers) { user in
                        entry(name: environment.displayName(for: user.id, in: chat), detail: user.id, userID: user.id)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(14)
        .frame(width: 280)
    }

    private var matchingMembers: [User] {
        environment.mentionableUsers(in: chat).filter {
            query.isEmpty || environment.displayName(for: $0.id, in: chat).localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func entry(name: String, detail: String, userID: String?) -> some View {
        Button {
            draft.addMention(userID: userID)
            didSelect()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(draft.mentions.contains(MentionTarget(userID: userID)))
    }
}
