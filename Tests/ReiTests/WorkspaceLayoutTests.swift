import AppKit
import ReiCore
import ReiProtocol
import SwiftUI
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Workspace Layout", .serialized)
@MainActor
struct WorkspaceLayoutTests {
    @Test("The inspector retains basic information and members without exposing unsupported protocol tools")
    func protocolSections() {
        let v12 = ConversationContentCapabilities(
            protocolChoice: .oneBotV12, scene: .group, canInteract: true, role: .owner)
        #expect(
            ConversationInspectorSection.available(capabilities: v12, supportsSettings: false) == [.overview, .members])
        let v11 = ConversationContentCapabilities(
            protocolChoice: .oneBotV11, scene: .group, canInteract: true, role: .owner)
        #expect(
            ConversationInspectorSection.available(capabilities: v11, supportsSettings: true) == [
                .overview, .members, .files, .settings,
            ])
        let temporary = ConversationContentCapabilities(
            protocolChoice: .milky, scene: .temp, canInteract: true, role: nil)
        #expect(
            ConversationInspectorSection.available(capabilities: temporary, supportsSettings: true) == [
                .overview, .settings,
            ])
    }

    @Test("Conversation tools fit the narrow inspector and render with populated light and dark workspaces")
    func renderWorkspace() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        for section in ConversationInspectorSection.allCases {
            try await render(
                ConversationInspectorView(
                    environment: fixture.environment, chat: fixture.chat, section: .constant(section)),
                size: CGSize(width: 320, height: 680), name: "inspector-" + section.rawValue.lowercased()
            )
        }
        try await render(
            WorkspaceInspectorView(
                environment: fixture.environment, tab: .constant(.events), section: .constant(.overview), close: {}),
            size: CGSize(width: 320, height: 680), name: "events", scheme: .dark
        )
        for width in [980.0, 1320.0] {
            for scheme in [ColorScheme.light, .dark] {
                try await render(
                    RootView(environment: fixture.environment, selectedSettingsTab: .constant(.connection)),
                    size: CGSize(width: width, height: 780),
                    name: "workspace-\(Int(width))-\(scheme == .light ? "light" : "dark")", scheme: scheme
                )
            }
        }
    }

    private func render<V: View>(_ content: V, size: CGSize, name: String, scheme: ColorScheme = .light) async throws {
        let controller = NSHostingController(
            rootView: content.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, scheme))
        let window = NSWindow(contentViewController: controller)
        let view = controller.view
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.setContentSize(size)
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.width <= size.width + 1, "\(name) must fit its viewport")
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        if let path = ProcessInfo.processInfo.environment["REI_WORKSPACE_PREVIEW_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try #require(image.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    @MainActor
    private struct Fixture {
        let directory: URL
        let defaultsName: String
        let defaults: UserDefaults
        let environment: AppEnvironment
        let chat = Chat(scene: .group, peerID: "80123456", selfID: "10001")

        init() async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "Rei-Workspace-\(UUID().uuidString)")
            let store = try ReiStore()
            let users = [
                User(id: "10001", name: "Rei Bot"), User(id: "10002", name: "Akashina"),
                User(id: "10003", name: "Alex Chen"),
            ]
            for user in users { try await store.save(user) }
            try await store.save(Group(id: chat.peerID, name: "Rei · Client Development"))
            for user in users {
                try await store.save(
                    GroupMember(groupID: chat.peerID, userID: user.id, role: user.id == "10002" ? .owner : .member))
            }
            defaultsName = "dev.rei.tests.workspace.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: defaultsName))
            environment = AppEnvironment(
                store: store, assetStore: try AssetStore(directory: directory.appendingPathComponent("assets")),
                appLog: AppLog(directory: directory.appendingPathComponent("logs"), emitUnifiedLog: false),
                defaults: defaults
            )
            await environment.setBotUser("10001")
            environment.setActiveUser("10002")
            environment.selectedProtocol = .milky
            try await environment.groupMembers(in: chat.peerID)
            let model = ConversationContentModel(environment: environment, chat: chat)
            try await model.postAnnouncement(
                content:
                    "Shared files and highlights are now available beside the conversation. Keep this panel open while you work.",
                image: nil)
            try await model.createFolder(name: "Release Documents")
            let source = directory.appendingPathComponent("Protocol compatibility notes.txt")
            try Data("Release notes".utf8).write(to: source)
            try await model.uploadFile(at: source)
            for (index, text) in [
                "Let's review the conversation layout.",
                "Members, files and announcements now live in the right sidebar.",
                "The chat stays visible while we check the protocol events.",
            ].enumerated() {
                let message = try await environment.platform.sendMessage(
                    scene: .group, peerID: chat.peerID, senderID: users[index].id, selfID: chat.selfID,
                    content: [.text(text)])
                if index == 1 { try await model.setHighlight(message, enabled: true) }
            }
            try await model.setPinned(true)
            environment.selectChat(chat)
        }

        func remove() {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
