import ReiCore
import ReiProtocol
import SwiftUI

/// The singleton main window: a stable conversation sidebar, a wide chat canvas,
/// and a contextual inspector for conversation tools and protocol traffic.
@MainActor
public struct RootView: View {
    let environment: AppEnvironment
    let showcase: ShowcaseSession?
    @Binding private var selectedSettingsTab: ReiSettingsTab

    @SceneStorage("workspace.showingSidebar") private var showingSidebar = true
    @SceneStorage("workspace.showingInspector") private var showingInspector = true
    @SceneStorage("workspace.inspectorTab") private var inspectorTab = WorkspaceInspectorTab.conversation
    @State private var conversationSection = ConversationInspectorSection.overview
    @State private var showingNewUser = false
    @State private var showingAddFriend = false
    @State private var showingNewGroup = false

    public init(
        environment: AppEnvironment,
        selectedSettingsTab: Binding<ReiSettingsTab>,
        showcase: ShowcaseSession? = nil
    ) {
        self.environment = environment
        self.showcase = showcase
        _selectedSettingsTab = selectedSettingsTab
    }

    public var body: some View {
        HSplitView {
            if showingSidebar {
                SidebarView(
                    environment: environment,
                    selectedSettingsTab: $selectedSettingsTab,
                    createUser: { showingNewUser = true },
                    addFriend: { showingAddFriend = true },
                    createGroup: { showingNewGroup = true },
                    inspect: inspectConversation,
                    showcaseConnection: showcase?.connection
                )
                .background { SidebarMaterial().ignoresSafeArea(.container, edges: .vertical) }
                .frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
            }
            ChatView(
                environment: environment, inspect: inspectConversation,
                showingInspector: showingInspector, toggleInspector: { showingInspector.toggle() },
                showcase: showcase
            )
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            if showingInspector {
                WorkspaceInspectorView(
                    environment: environment, tab: $inspectorTab, section: $conversationSection,
                    close: { showingInspector = false }
                )
                .background { SidebarMaterial().ignoresSafeArea(.container, edges: .vertical) }
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 560)
            }
        }
        .navigationTitle(environment.selectedChat.map { environment.conversationTitle(for: $0) } ?? "Rei")
        .task { await showcase?.run() }
        .onChange(of: environment.selectedChat) { _, chat in showcase?.selectedChatChanged(chat) }
        .toolbar {
            if let showcase {
                ToolbarItem(placement: .primaryAction) { ShowcaseControls(session: showcase) }
            }
            ToolbarItem(placement: .navigation) {
                Button(showingSidebar ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.leading") {
                    showingSidebar.toggle()
                }
                .help(showingSidebar ? "Hide Sidebar" : "Show Sidebar")
            }
        }
        .sheet(isPresented: $showingNewUser) {
            NewUserSheet(environment: environment)
        }
        .sheet(isPresented: $showingAddFriend) {
            UserSelectionSheet(environment: environment, purpose: .friend)
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupSheet(environment: environment)
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { environment.lastError != nil },
                set: { if !$0 { environment.lastError = nil } }
            )
        ) {
            Button("OK") { environment.lastError = nil }
        } message: {
            Text(environment.lastError ?? "")
        }
        .focusedSceneValue(\.reiCommandActions, commandActions)
        .frame(minWidth: 980, minHeight: 620)
    }

    private func inspectConversation(_ chat: Chat, _ section: ConversationInspectorSection) {
        environment.selectChat(chat)
        conversationSection = section
        inspectorTab = .conversation
        showingInspector = true
    }

    private var commandActions: ReiCommandActions {
        ReiCommandActions(
            createUser: { showingNewUser = true },
            createGroup: { showingNewGroup = true },
            toggleConnection: toggleConnection,
            toggleInspector: { showingInspector.toggle() },
            canCreateGroup: !environment.users.isEmpty,
            isConnected: showcase?.connection.isActive ?? environment.sessionState.isActive,
            isInspectorPresented: showingInspector
        )
    }

    private func toggleConnection() {
        Task {
            if let showcase {
                await showcase.connection.toggle()
                return
            }
            if environment.sessionState.isActive {
                await environment.disconnect()
            } else {
                await environment.connect()
            }
        }
    }
}
