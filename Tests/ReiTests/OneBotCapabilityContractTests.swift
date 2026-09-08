import AVFoundation
import CryptoKit
import Foundation
import ReiCore
import ReiProtocol
import Testing

@testable import ReiOneBot

private final class OneBotUploadURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.value(forHTTPHeaderField: "X-Test-Upload") == "expected" ? 200 : 403
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("remote bytes".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Expectations come from the OneBot standards, not the adapter's action manifest:
/// https://12.onebot.dev/interface/file/actions/
/// https://12.onebot.dev/interface/user/actions/
/// https://12.onebot.dev/interface/group/actions/
/// https://12.onebot.dev/connect/data-protocol/action-response/
/// https://github.com/botuniverse/onebot-11/blob/master/api/public.md
/// https://github.com/botuniverse/onebot-11/blob/master/message/string.md
@Suite("OneBot capability contracts")
struct OneBotCapabilityContractTests {
    private struct Fixture {
        let root: URL
        let store: ReiStore
        let media: MediaService
        let adapter: OneBotProtocolImplementation

        static func make(_ version: OneBotVersion, session: URLSession = .shared) async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = try ReiStore()
            let assets = try AssetStore(directory: root)
            let media = MediaService(assetStore: assets, store: store, session: session)
            try await store.save(User(id: "100", name: "Bot"))
            try await store.save(User(id: "200", name: "Alice", nickname: "Ally"))
            try await store.save(Group(id: "300", name: "Group"))
            try await store.save(GroupMember(groupID: "300", userID: "100", role: .owner))
            try await store.save(GroupMember(groupID: "300", userID: "200", card: "Alice G."))
            let conversion = MediaConversionService(
                media: media,
                ffmpegURL: ProcessInfo.processInfo.environment["REI_TEST_FFMPEG"].map { URL(fileURLWithPath: $0) }
            )
            let platform = PlatformService(store: store)
            await platform.registerBot(id: "100")
            return Fixture(
                root: root, store: store, media: media,
                adapter: OneBotProtocolImplementation(
                    version: version, selfID: "100", platform: platform,
                    assetResolver: OneBotAssetResolver(media: media, conversion: conversion)
                )
            )
        }

        func call(_ action: String, _ params: JSONValue = [:]) async -> ProtocolReply {
            await adapter.handle(call: ProtocolCall(name: action, parameters: params))
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private let bytes = Data("Hello, OneBot!".utf8)
    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("CQ syntax preserves parameter commas, equals, unknown types, and literal escapes")
    func cqSyntax() {
        let wire = "&amp;#91;[CQ:share,title=A&#44;B=url&amp;x,content=&#91;x&#93;][CQ:shake]"
        let segments = OneBotCQCode.decode(wire)
        #expect(
            segments == [
                ["type": "text", "data": ["text": "&#91;"]],
                ["type": "share", "data": ["title": "A,B=url&x", "content": "[x]"]],
                ["type": "shake", "data": [:]],
            ])
        #expect(OneBotCQCode.decode(OneBotCQCode.encode(segments)) == segments)
        #expect(
            OneBotCQCode.decode("before [CQ:face,id") == [["type": "text", "data": ["text": "before [CQ:face,id"]]])
    }

    @Test("V12 URL upload supplies headers and HTTP failures never become uploaded files")
    func urlUpload() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OneBotUploadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let fixture = try await Fixture.make(.v12, session: session)
        defer { fixture.cleanUp() }
        let uploaded = await fixture.call(
            "upload_file",
            [
                "type": "url", "name": "download.txt", "url": "https://upload.test/file",
                "headers": ["X-Test-Upload": "expected"],
            ])
        #expect(uploaded.isSuccess)
        let id = try #require(uploaded.data["file_id"]?.stringValue)
        let data = await fixture.call("get_file", ["file_id": .string(id), "type": "data"])
        #expect(data.data["data"] == .string(Data("remote bytes".utf8).base64EncodedString()))
        let rejected = await fixture.call(
            "upload_file",
            [
                "type": "url", "name": "download.txt", "url": "https://upload.test/file",
            ])
        #expect(!rejected.isSuccess)
    }

    @Test("V11 get_image returns the stored media bytes at a real local path")
    func imageLookup() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let asset = try #require(await fixture.media.store(data: bytes, name: "test.png"))
        let reply = await fixture.call("get_image", ["file": .string(asset.id)])
        #expect(reply.isSuccess)
        let path = try #require(reply.data["file"]?.stringValue)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        let repeated = await fixture.call("get_image", ["file": .string(path)])
        #expect(repeated.isSuccess)
        #expect(try await fixture.store.asset(id: asset.id)?.name == "test.png")
    }

    @Test("V11 get_record returns a real converted file and rejects unsupported output formats")
    func recordConversion() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let input = fixture.root.appendingPathComponent("source.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<1600 { samples[index] = Float(sin(Double(index) * 0.1) * 0.2) }
        do {
            let file = try AVAudioFile(forWriting: input, settings: format.settings)
            try file.write(from: buffer)
        }
        let asset = try #require(try await fixture.media.ingest(reference: input.path, suggestedName: "source.wav"))
        let reply = await fixture.call("get_record", ["file": .string(asset.id), "out_format": "m4a"])
        #expect(reply.isSuccess)
        let path = try #require(reply.data["file"]?.stringValue)
        let decoded = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        #expect(decoded.length > 0)
        #expect(decoded.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatMPEG4AAC)
        let invalid = await fixture.call("get_record", ["file": .string(asset.id), "out_format": "imaginary"])
        #expect(!invalid.isSuccess)
    }

    @Test("V12 upload data creates a reusable file ID and get_file returns bytes, name, path, URL")
    func fileUploadAndGet() async throws {
        let fixture = try await Fixture.make(.v12)
        defer { fixture.cleanUp() }
        let upload = await fixture.call(
            "upload_file",
            [
                "type": "data", "name": "greeting.txt", "data": .string(bytes.base64EncodedString()),
                "sha256": .string(hash(bytes)),
            ])
        #expect(upload.isSuccess)
        let id = try #require(upload.data["file_id"]?.stringValue)
        let file = await fixture.call("get_file", ["file_id": .string(id), "type": "data"])
        #expect(file.isSuccess)
        #expect(file.data["name"] == "greeting.txt")
        #expect(file.data["data"] == .string(bytes.base64EncodedString()))
        let path = await fixture.call("get_file", ["file_id": .string(id), "type": "path"])
        let location = try #require(path.data["path"]?.stringValue)
        #expect(try Data(contentsOf: URL(fileURLWithPath: location)) == bytes)
        let url = await fixture.call("get_file", ["file_id": .string(id), "type": "url"])
        #expect(url.data["url"]?.stringValue?.hasPrefix("http://") == true)
        let sent = await fixture.call(
            "send_message",
            [
                "detail_type": "group", "group_id": "300",
                "message": [["type": "file", "data": ["file_id": .string(id)]]],
            ])
        #expect(sent.isSuccess)
        let messageID = try #require(sent.data["message_id"]?.stringValue)
        let message = try #require(try await fixture.store.message(id: messageID))
        guard case .file(let asset) = message.content.first else {
            Issue.record("Uploaded file must become a file segment")
            return
        }
        #expect(asset.name == "greeting.txt")
    }

    @Test("V12 path upload reads the specified file; unsupported transfer types fail")
    func pathUpload() async throws {
        let fixture = try await Fixture.make(.v12)
        defer { fixture.cleanUp() }
        let path = fixture.root.appendingPathComponent("input.txt")
        try bytes.write(to: path)
        let upload = await fixture.call(
            "upload_file",
            [
                "type": "path", "name": "renamed.txt", "path": .string(path.path),
            ])
        #expect(upload.isSuccess)
        let id = try #require(upload.data["file_id"]?.stringValue)
        let unsupported = await fixture.call("get_file", ["type": "imaginary", "file_id": .string(id)])
        #expect(unsupported.retcode == 10004)
    }

    @Test("V12 rejects malformed base64 and SHA mismatches rather than succeeding")
    func invalidUpload() async throws {
        let fixture = try await Fixture.make(.v12)
        defer { fixture.cleanUp() }
        let malformed = await fixture.call("upload_file", ["type": "data", "name": "x", "data": "!invalid!"])
        #expect(!malformed.isSuccess)
        let mismatch = await fixture.call(
            "upload_file",
            [
                "type": "data", "name": "x", "data": .string(bytes.base64EncodedString()),
                "sha256": .string(String(repeating: "0", count: 64)),
            ])
        #expect(!mismatch.isSuccess)
    }

    @Test("V12 fragmented transfers reconstruct out-of-order chunks and return requested slices")
    func fragmentedFile() async throws {
        let fixture = try await Fixture.make(.v12)
        defer { fixture.cleanUp() }
        let prepare = await fixture.call(
            "upload_file_fragmented",
            [
                "stage": "prepare", "name": "parts.txt", "total_size": .number(Double(bytes.count)),
            ])
        #expect(prepare.isSuccess)
        let temporaryID = try #require(prepare.data["file_id"]?.stringValue)
        for range in [5..<bytes.count, 0..<5] {
            let transfer = await fixture.call(
                "upload_file_fragmented",
                [
                    "stage": "transfer", "file_id": .string(temporaryID),
                    "offset": .number(Double(range.lowerBound)),
                    "data": .string(bytes.subdata(in: range).base64EncodedString()),
                ])
            #expect(transfer.isSuccess)
        }
        let finish = await fixture.call(
            "upload_file_fragmented",
            [
                "stage": "finish", "file_id": .string(temporaryID), "sha256": .string(hash(bytes)),
            ])
        #expect(finish.isSuccess)
        let id = try #require(finish.data["file_id"]?.stringValue)
        let download = await fixture.call("get_file_fragmented", ["stage": "prepare", "file_id": .string(id)])
        #expect(download.data["name"] == "parts.txt")
        #expect(download.data["total_size"]?.intValue == bytes.count)
        #expect(download.data["sha256"] == .string(hash(bytes)))
        let slice = await fixture.call(
            "get_file_fragmented",
            [
                "stage": "transfer", "file_id": .string(id), "offset": 2, "size": 4,
            ])
        #expect(slice.data["data"] == .string(bytes.subdata(in: 2..<6).base64EncodedString()))
        let obsoleteSession = await fixture.call(
            "upload_file_fragmented",
            [
                "stage": "transfer", "file_id": .string(temporaryID), "offset": 0, "data": "YWJj",
            ])
        #expect(!obsoleteSession.isSuccess)
    }

    @Test("V12 cannot finish a partial upload or read beyond a file")
    func fragmentedBounds() async throws {
        let fixture = try await Fixture.make(.v12)
        defer { fixture.cleanUp() }
        let prepare = await fixture.call("upload_file_fragmented", ["stage": "prepare", "name": "x", "total_size": 8])
        let id = try #require(prepare.data["file_id"]?.stringValue)
        let partial = await fixture.call(
            "upload_file_fragmented",
            [
                "stage": "finish", "file_id": .string(id), "sha256": .string(hash(Data(repeating: 0, count: 8))),
            ])
        #expect(!partial.isSuccess)
        let outside = await fixture.call(
            "upload_file_fragmented",
            [
                "stage": "transfer", "file_id": .string(id), "offset": 7, "data": "YWJj",
            ])
        #expect(!outside.isSuccess)
        let upload = await fixture.call("upload_file", ["type": "data", "name": "x", "data": "YWJj"])
        let storedID = try #require(upload.data["file_id"]?.stringValue)
        let negative = await fixture.call(
            "get_file_fragmented",
            [
                "stage": "transfer", "file_id": .string(storedID), "offset": -1, "size": 1,
            ])
        #expect(!negative.isSuccess)
    }

    @Test("V11 parses CQ by default, decodes entities once, and honors auto_escape")
    func cqInput() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let source = "Hello &#91;x&#93; &amp;#91;[CQ:at,qq=200][CQ:face,id=178]"
        let sent = await fixture.call("send_group_msg", ["group_id": "300", "message": .string(source)])
        #expect(sent.isSuccess)
        let id = try #require(sent.data["message_id"]?.stringValue)
        let message = try #require(try await fixture.store.message(id: id))
        #expect(message.content == [.text("Hello [x] &#91;"), .mention(userID: "200"), .face(id: "178", name: nil)])
        let literal = await fixture.call(
            "send_group_msg",
            [
                "group_id": "300", "message": .string(source), "auto_escape": true,
            ])
        let literalID = try #require(literal.data["message_id"]?.stringValue)
        let literalMessage = try #require(try await fixture.store.message(id: literalID))
        #expect(literalMessage.content == [.text(source)])
    }

    @Test("V11 raw_message is CQ string including escaped text and segments")
    func cqOutput() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let message = Message(
            scene: .group, peerID: "300", senderID: "200", selfID: "100",
            content: [.text("[x] & ,"), .mention(userID: "100"), .face(id: "178", name: nil)], direction: .outgoing
        )
        let frames = await fixture.adapter.encode(event: DomainEvent(selfID: "100", payload: .message(message)))
        #expect(frames.first?.payload["raw_message"] == "&#91;x&#93; &amp; ,[CQ:at,qq=100][CQ:face,id=178]")
    }

    @Test("V11 get_forward_msg resolves persisted nodes with names and content")
    func forwardLookup() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let node = MessageSegment.ForwardNode(senderID: "200", senderName: "Alice", content: [.text("Earlier")])
        try await fixture.store.save(
            Message(
                scene: .group, peerID: "300", senderID: "200", selfID: "100",
                content: [.forward(id: "bundle", nodes: [node])], direction: .outgoing
            ))
        let reply = await fixture.call("get_forward_msg", ["id": "bundle"])
        #expect(reply.isSuccess)
        let segment = try #require(reply.data["message"]?.arrayValue?.first)
        #expect(segment["type"] == "node")
        #expect(segment["data"]?["user_id"]?.stringValue == "200")
        #expect(segment["data"]?["nickname"] == "Alice")
        #expect(segment["data"]?["content"] == [["type": "text", "data": ["text": "Earlier"]]])
        let missing = await fixture.call("get_forward_msg", ["id": "missing"])
        #expect(!missing.isSuccess)
    }

    @Test("V11 custom forward nodes form a retrievable bundle and nested CQ content is decoded")
    func sendForwardNodes() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let reply = await fixture.call(
            "send_group_msg",
            [
                "group_id": "300",
                "message": [
                    [
                        "type": "node",
                        "data": ["user_id": "200", "nickname": "Alice", "content": "[CQ:face,id=178]Hello"],
                    ],
                    [
                        "type": "node",
                        "data": [
                            "user_id": "100", "nickname": "Bot",
                            "content": [["type": "text", "data": ["text": "Reply"]]],
                        ],
                    ],
                ],
            ])
        #expect(reply.isSuccess)
        let id = try #require(reply.data["message_id"]?.stringValue)
        let message = try #require(try await fixture.store.message(id: id))
        guard case .forward(let bundleID, let nodes) = message.content.first else {
            Issue.record("Node segments must form a merged forward message")
            return
        }
        #expect(nodes.count == 2)
        #expect(nodes.first?.content == [.face(id: "178", name: nil), .text("Hello")])
        let fetched = await fixture.call("get_forward_msg", ["id": .string(bundleID)])
        #expect(fetched.data["message"]?.arrayValue?.count == 2)
    }

    @Test("V12 uses its own user/member response names")
    func v12EntityNames() async throws {
        let fixture = try await Fixture.make(.v12)
        defer { fixture.cleanUp() }
        let user = await fixture.call("get_user_info", ["user_id": "200"])
        #expect(user.isSuccess)
        #expect(user.data["user_name"] == "Ally")
        #expect(user.data["user_displayname"] != nil)
        #expect(user.data["user_remark"] == "")
        let member = await fixture.call("get_group_member_info", ["group_id": "300", "user_id": "200"])
        #expect(member.data["user_name"] == "Ally")
        #expect(member.data["user_displayname"] == "Alice G.")
    }

    @Test("V12 manifest contains only V12 actions and cross-version calls fail")
    func versionBoundaries() async throws {
        let v12 = try await Fixture.make(.v12)
        defer { v12.cleanUp() }
        let manifest = await v12.call("get_supported_actions")
        let actions = try #require(manifest.data.arrayValue).compactMap(\.stringValue)
        #expect(actions.contains("send_message"))
        #expect(actions.contains("upload_file"))
        #expect(!actions.contains("send_msg"))
        #expect(!actions.contains("set_group_ban"))
        let wrong = await v12.call("send_group_msg", ["group_id": "300", "message": "x"])
        #expect(wrong.retcode == 10002)
        let v11 = try await Fixture.make(.v11)
        defer { v11.cleanUp() }
        let v12Only = await v11.call("upload_file", ["type": "data", "name": "x", "data": "YWJj"])
        #expect(!v12Only.isSuccess)
    }

    @Test("V12 rejects unsupported message segments and missing file IDs instead of silently dropping them")
    func invalidMessageSegments() async throws {
        let fixture = try await Fixture.make(.v12)
        defer { fixture.cleanUp() }
        let unknown = await fixture.call(
            "send_message",
            [
                "detail_type": "group", "group_id": "300",
                "message": [["type": "invented", "data": [:]]],
            ])
        #expect(unknown.retcode == 10005)
        let missingFile = await fixture.call(
            "send_message",
            [
                "detail_type": "group", "group_id": "300",
                "message": [
                    ["type": "text", "data": ["text": "before"]],
                    ["type": "image", "data": ["file_id": "does-not-exist"]],
                ],
            ])
        // A known segment with an unknown resource is an execution/logic error;
        // 10007 is reserved for parameter semantics the implementation does not support.
        #expect(missingFile.retcode == 35000)
        let malformed = await fixture.call(
            "send_message",
            [
                "detail_type": "group", "group_id": "300", "message": [["type": "image", "data": [:]]],
            ])
        #expect(malformed.retcode == 10006)
        let unknownUser = await fixture.call("get_user_info", ["user_id": "missing"])
        #expect(unknownUser.retcode == 35000)
    }

    @Test("V11 send_like defaults to one and persists the operator's profile likes")
    func profileLikes() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let reply = await fixture.call("send_like", ["user_id": "200"])
        #expect(reply.isSuccess)
        let likes = try await fixture.store.profileLikes(userID: "200")
        #expect(likes.first?.operatorID == "100")
        #expect(likes.first?.count == 1)
        let invalid = await fixture.call("send_like", ["user_id": "200", "times": 11])
        #expect(!invalid.isSuccess)
        #expect(try await fixture.store.profileLikes(userID: "200").first?.count == 1)
        let remaining = await fixture.call("send_like", ["user_id": "200", "times": 9])
        #expect(remaining.isSuccess)
        let exceeded = await fixture.call("send_like", ["user_id": "200"])
        #expect(!exceeded.isSuccess)
        #expect(try await fixture.store.profileLikes(userID: "200").first?.count == 10)
    }

    @Test("OneBot message IDs and partial upload IDs remain scoped to their implementation")
    func accountIsolation() async throws {
        let fixture = try await Fixture.make(.v11)
        defer { fixture.cleanUp() }
        let message = Message(
            scene: .group, peerID: "300", senderID: "200", selfID: "other-bot",
            content: [.text("Other account")], direction: .outgoing
        )
        try await fixture.store.save(message)
        let read = await fixture.call("get_msg", ["message_id": .string(message.id)])
        #expect(!read.isSuccess)
        let recall = await fixture.call("delete_msg", ["message_id": .string(message.id)])
        #expect(!recall.isSuccess)
        #expect(try await fixture.store.message(id: message.id)?.isRecalled == false)

        let first = try await Fixture.make(.v12)
        defer { first.cleanUp() }
        let prepare = await first.call("upload_file_fragmented", ["stage": "prepare", "name": "x", "total_size": 3])
        let temporaryID = try #require(prepare.data["file_id"]?.stringValue)
        let other = OneBotProtocolImplementation(
            version: .v12, selfID: "different-bot", platform: PlatformService(store: first.store),
            assetResolver: OneBotAssetResolver(media: first.media)
        )
        let transfer = await other.handle(
            call: ProtocolCall(
                name: "upload_file_fragmented",
                parameters: [
                    "stage": "transfer", "file_id": .string(temporaryID), "offset": 0, "data": "YWJj",
                ]))
        #expect(!transfer.isSuccess)
        let rawPath = await first.call("get_file", ["file_id": .string(first.root.path), "type": "data"])
        #expect(rawPath.retcode == 35000)
        let missingID = String(repeating: "a", count: 64)
        try await first.store.save(Asset(id: missingID, name: "missing.bin", source: .inline))
        let lostFile = await first.call("get_file", ["file_id": .string(missingID), "type": "url"])
        #expect(lostFile.retcode == 35000)
    }
}
