import SwiftUI

/// Workspace actions stay with the source list, independent of the selected chat.
struct SidebarHeader: View {
    let environment: AppEnvironment
    @Binding var query: String
    let createUser: () -> Void
    let addFriend: () -> Void
    let createGroup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Rei").font(.title2.weight(.semibold))
                Spacer()
                Menu {
                    Button("New Persona…", systemImage: "person.badge.plus", action: createUser)
                    Button("Add Friend…", systemImage: "person.crop.circle.badge.plus", action: addFriend)
                        .disabled(environment.addableFriendUsers.isEmpty)
                    Button("New Group…", systemImage: "person.3", action: createGroup)
                        .disabled(environment.users.isEmpty)
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .labelStyle(.iconOnly)
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Create a persona, friend connection, or group")
            }
            NativeSearchField(text: $query, prompt: "Search conversations", accessibilityLabel: "Search conversations")
                .frame(height: 28)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }
}
