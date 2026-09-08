import Foundation
import Observation
import ReiCore
import ReiLogging
import ReiProtocol

/// An opt-in, in-memory platform. The normal library and preferences are never
/// opened by this launch mode; all mutations still use the real platform service.
@Observable
@MainActor
public final class ShowcaseSession {
    public let environment: AppEnvironment
    let connection: ShowcaseConnection
    public var isPlaying = true
    public var isFollowing = true
    public private(set) var isPrepared = false
    public private(set) var stepIndex = 0
    public private(set) var cycle = 0
    public private(set) var currentChat: Chat
    public private(set) var errorMessage: String?

    static let botID = "900001"
    static let userID = "900002"
    static let friendID = "900003"
    static let groupChat = Chat(scene: .group, peerID: "900100", selfID: botID)
    static let directChat = Chat(scene: .friend, peerID: userID, selfID: botID)
    static let stepCount = 30

    private var media: ShowcaseMedia?
    private var anchor: Message?
    private var imageMessage: Message?
    private var recalledMessage: Message?
    private var isAdvancing = false
    private var isPreparing = false

    public init(appLog: AppLog, cacheDirectory: URL) throws {
        let suite = "dev.rei.showcase.\(cacheDirectory.lastPathComponent)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
        defaults.removePersistentDomain(forName: suite)
        environment = AppEnvironment(
            store: try ReiStore(), assetStore: try AssetStore(directory: cacheDirectory),
            appLog: appLog, defaults: defaults
        )
        connection = ShowcaseConnection(environment: environment)
        currentChat = Self.groupChat
    }

    public static func requested(in arguments: [String]) -> Bool { arguments.contains("--demo") }

    func prepare() async throws {
        guard !isPrepared, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        let media = try await ShowcaseMedia.load(into: environment)
        self.media = media
        let avatar = try ShowcaseMedia.resource("Akame", extension: "png").path
        for user in [
            User(id: Self.botID, name: "Akame", avatar: avatar, sign: "一起看看 Rei 的新消息吧。"),
            User(id: Self.userID, name: "Akashina"),
            User(id: Self.friendID, name: "Yuki"),
        ] { try await environment.store.save(user) }
        try await environment.store.save(Group(id: Self.groupChat.peerID, name: "Akame · 展示空间", avatar: avatar))
        for id in [Self.botID, Self.userID, Self.friendID] {
            try await environment.store.save(
                GroupMember(
                    groupID: Self.groupChat.peerID, userID: id,
                    role: id == Self.userID ? .owner : id == Self.botID ? .admin : .member,
                    title: id == Self.botID ? "向导" : ""
                ))
        }
        try await environment.store.save(Friendship(userID: Self.botID, friendID: Self.userID))
        await environment.setBotUser(Self.botID)
        environment.setActiveUser(Self.userID)
        environment.selectedProtocol = .milky
        environment.settings.transport = .milkyService
        try await environment.groupMembers(in: Self.groupChat.peerID)
        try await environment.platform.setPeerPin(in: Self.groupChat, isPinned: true)
        try await environment.platform.setPeerPin(in: Self.directChat, isPinned: true)
        try await environment.platform.postAnnouncement(
            groupID: Self.groupChat.peerID, operatorID: Self.userID,
            content: "欢迎来到 Akame 的展示空间。消息会每四秒到达一次；可以暂停、浏览引用、播放媒体，也可以打开右栏查看群公告、共享文件和精华。", image: media.image
        )
        try await environment.platform.shareFile(
            in: Self.groupChat, operatorID: Self.userID, asset: media.file, name: media.file.name)
        let fileURL = try await environment.attachmentURL(for: media.file)
        try await environment.platform.shareFile(
            in: Self.directChat, operatorID: Self.botID, asset: media.file, name: media.file.name,
            fileHash: FileFingerprint.triSHA1(at: fileURL)
        )
        // Both fixed conversations are visible immediately, before playback starts.
        try await environment.platform.sendMessage(
            scene: .friend, peerID: Self.userID, senderID: Self.botID, selfID: Self.botID,
            content: [.text("你好，我是 Akame ☀️\n等群聊展示结束，我们再在这里慢慢聊。")]
        )
        environment.selectChat(Self.groupChat)
        isPrepared = true
    }

    public func run() async {
        do {
            try await prepare()
            connection.connect()
            while !Task.isCancelled {
                if isPlaying { try await advance() }
                try await Task.sleep(for: .seconds(isPlaying ? 4 : 0.25))
            }
        } catch is CancellationError {
            // Closing the window stops the producer without touching normal data.
        } catch {
            errorMessage = error.localizedDescription
            isPlaying = false
        }
        await connection.disconnect()
    }

    func advance() async throws {
        guard isPrepared, let media, !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }
        let chat = stepIndex < 18 ? Self.groupChat : Self.directChat
        if stepIndex == 0 || stepIndex == 18 {
            // Reset only the next demo conversation, while the other one remains
            // visible. Manual browsing pauses playback before reaching this point.
            if cycle > 0 { try await environment.store.deleteMessages(in: chat) }
            anchor = nil
            imageMessage = nil
            recalledMessage = nil
        }
        currentChat = chat
        if isFollowing { environment.selectChat(chat) }
        try await performStep(stepIndex, in: chat, media: media)
        stepIndex += 1
        if stepIndex == Self.stepCount {
            stepIndex = 0
            cycle += 1
        }
    }

    public func selectedChatChanged(_ chat: Chat?) {
        guard isFollowing, chat != currentChat, isPrepared else { return }
        isFollowing = false
        isPlaying = false
    }

    public func resumeFollowing() {
        isFollowing = true
        environment.selectChat(currentChat)
    }

    @discardableResult
    private func send(_ content: [MessageSegment], in chat: Chat, from userID: String) async throws -> Message {
        try await environment.platform.sendMessage(
            scene: chat.scene, peerID: chat.peerID, senderID: userID, selfID: Self.botID, content: content)
    }

    private func performStep(_ index: Int, in chat: Chat, media: ShowcaseMedia) async throws {
        switch index {
        case 0:
            anchor = try await send([.text("午后好，欢迎来到 Akame 的小小展示空间 ☀️\n先从一条普通消息开始。")], in: chat, from: Self.botID)
        case 1:
            try await send(
                [.reply(messageID: try reference(anchor)), .text("收到！今天想看图片、转发，还有会动的 Akame。")], in: chat,
                from: Self.userID)
        case 2:
            imageMessage = try await send(
                [.text("这是今天的主角。点击图片可以查看原图。"), .image(media.image)], in: chat, from: Self.botID)
        case 3:
            imageMessage = try await send([.text("转一圈—— ☀️"), .image(media.animation)], in: chat, from: Self.friendID)
        case 4:
            for id in [Self.botID, Self.userID, Self.friendID] {
                try await environment.platform.react(
                    messageID: try reference(imageMessage), userID: id,
                    reaction: Reaction(kind: .emoji, value: "128155"), added: true)
            }
            try await send([.text("三个人都给图片点了 💛，回应计数会实时更新。")], in: chat, from: Self.userID)
        case 5:
            try await send(
                [.mention(userID: Self.botID), .text(" 来听一下这段轻柔的提示音。"), .record(media.audio, duration: 5)], in: chat,
                from: Self.userID)
        case 6:
            try await send([.text("同样的旋转也可以作为视频播放，支持进度和音量控制。"), .video(media.video)], in: chat, from: Self.botID)
        case 7:
            try await send([.text("把展示说明也放进群文件了。"), .file(media.file)], in: chat, from: Self.friendID)
        case 8:
            try await send(
                [.forward(id: "showcase-forward-\(cycle)", nodes: media.forwardNodes)], in: chat, from: Self.botID)
        case 9:
            recalledMessage = try await send([.text("这条消息等一会儿会被撤回，请留意占位和引用。")], in: chat, from: Self.friendID)
        case 10:
            try await send(
                [.reply(messageID: try reference(recalledMessage)), .text("引用已经建立，撤回后也会同步更新。")], in: chat,
                from: Self.userID)
        case 11:
            try await environment.platform.recallMessage(id: try reference(recalledMessage), operatorID: Self.friendID)
        case 12:
            try await environment.platform.setMessageEssence(
                messageID: try reference(imageMessage), operatorID: Self.userID, isSet: true)
            try await send([.text("主角图片已加入精华。可以在右栏 Highlights 中找到它。")], in: chat, from: Self.botID)
        case 13:
            try await send([.mention(userID: nil), .text(" 图片、文件、引用与转发都准备好啦 ✨")], in: chat, from: Self.userID)
        case 14:
            try await send(
                [
                    .text(
                        "长消息也要舒展地阅读。\n\n窗外的光慢慢移过桌面，新的消息落进聊天记录。每个人的头像、角色与时间各有位置，长短文字自然换行。\n\nEnglish · 日本語 · 简体中文\n☀️ 🌻 💛  数字 0123456789\n\n滚动时，玻璃输入区和操作控件保留自己的层次。"
                    )
                ], in: chat, from: Self.friendID)
        case 15:
            try await send(
                [.image(media.image), .text("静态图片和动态图片也可以组合在同一条消息里。"), .image(media.animation)], in: chat,
                from: Self.botID)
        case 16:
            let sequence = try await latestSequence(in: chat)
            try await environment.platform.markRead(in: chat, through: sequence)
        case 17:
            try await send([.text("接下来去私聊看看。手动切换会话会暂停自动演示，方便细看。")], in: chat, from: Self.botID)
        case 18:
            anchor = try await send([.text("这里是我们的私聊。群聊会保留在左侧，随时可以回来。")], in: chat, from: Self.botID)
        case 19:
            try await send(
                [.reply(messageID: try reference(anchor)), .text("喜欢这种慢慢收到消息的节奏。")], in: chat, from: Self.userID)
        case 20:
            try await send([.image(media.image)], in: chat, from: Self.botID)
        case 21:
            try await send([.text("再转一圈。"), .image(media.animation)], in: chat, from: Self.userID)
        case 22:
            try await send([.record(media.audio, duration: 5)], in: chat, from: Self.botID)
        case 23:
            try await send([.video(media.video)], in: chat, from: Self.userID)
        case 24:
            try await send([.file(media.file)], in: chat, from: Self.botID)
        case 25:
            try await send(
                [.forward(id: "showcase-dm-forward-\(cycle)", nodes: media.forwardNodes)], in: chat, from: Self.userID)
        case 26:
            recalledMessage = try await send([.text("私聊也支持撤回。")], in: chat, from: Self.botID)
        case 27:
            try await environment.platform.recallMessage(id: try reference(recalledMessage), operatorID: Self.botID)
        case 28:
            try await environment.platform.likeProfile(userID: Self.botID, operatorID: Self.userID, count: 1)
            try await send([.text("给 Akame 点了一个资料赞 💛。下一轮会重新展示这两个会话。")], in: chat, from: Self.userID)
        default:
            try await send([.text("准备好就再看一遍吧。也可以暂停演示，自己试试输入框和右栏工具。")], in: chat, from: Self.botID)
        }
    }

    private func reference(_ message: Message?) throws -> String {
        guard let message else { throw CocoaError(.coderValueNotFound) }
        return message.id
    }

    private func latestSequence(in chat: Chat) async throws -> Int64 {
        try await environment.store.messages(in: chat).last?.seq ?? 0
    }
}
