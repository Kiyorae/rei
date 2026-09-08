import Foundation
import ReiCore

@MainActor
struct ShowcaseMedia {
    let image: Asset
    let animation: Asset
    let audio: Asset
    let video: Asset
    let file: Asset

    static func resource(_ name: String, extension fileExtension: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension, subdirectory: "Showcase")
        else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "\(name).\(fileExtension)"])
        }
        return url
    }

    @MainActor
    static func load(into environment: AppEnvironment) async throws -> Self {
        func load(_ name: String, _ fileExtension: String) async throws -> Asset {
            let url = try resource(name, extension: fileExtension)
            guard let asset = await environment.ingestAttachment(at: url) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return asset
        }
        return try await Self(
            image: load("Akame", "png"), animation: load("Akame-Spin", "gif"), audio: load("Chime", "wav"),
            video: load("Akame-Spin", "mp4"), file: load("Readme", "txt")
        )
    }

    var forwardNodes: [MessageSegment.ForwardNode] {
        [
            .init(
                id: "demo-forward-original", senderID: ShowcaseSession.botID, senderName: "Akame",
                content: [.text("把今天的素材整理到一起。"), .image(image)]),
            .init(
                senderID: ShowcaseSession.userID, senderName: "Akashina",
                content: [.reply(messageID: "demo-forward-original"), .text("这里的引用指向转发内部的原消息。")]),
            .init(senderID: ShowcaseSession.friendID, senderName: "Yuki", content: [.image(animation)]),
            .init(senderID: ShowcaseSession.botID, senderName: "Akame", content: [.file(file)]),
            .init(
                senderID: ShowcaseSession.userID, senderName: "Akashina",
                content: [
                    .forward(
                        id: "demo-forward-nested",
                        nodes: [
                            .init(
                                senderID: ShowcaseSession.botID, senderName: "Akame", content: [.text("嵌套转发也有完整内容 ✨")])
                        ])
                ]),
        ]
    }
}
