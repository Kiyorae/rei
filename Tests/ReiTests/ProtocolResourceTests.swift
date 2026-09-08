import Foundation
import ReiCore
import ReiMilky
import ReiOneBot
import ReiProtocol
import Testing

@testable import ReiUI

/// Milky exposes only a temp_url string; OneBot V12 get_file(type: url) must
/// return an actual downloadable HTTP URL. Download grants are resource-specific
/// and do not disclose the protocol API access token.
@Suite("Protocol resource delivery")
struct ProtocolResourceTests {
    @Test("Signed download names belong to each link, even when different files share the same content hash")
    func resourceNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReiStore()
        let media = MediaService(assetStore: try AssetStore(directory: directory), store: store)
        let platform = PlatformService(store: store)
        let adapter = OneBotProtocolImplementation(
            version: .v12, selfID: "100", platform: platform, assetResolver: OneBotAssetResolver(media: media)
        )
        let session = ProtocolSession(
            implementation: adapter, platform: platform,
            settings: ConnectionSettings(transport: .webSocketServer, port: 0)
        )
        try await session.start()
        do {
            let bytes = Data("same bytes, different file entries".utf8)
            let asset = try #require(await media.store(data: bytes, name: "storage-name.bin"))
            var first = asset
            first.name = "first report.txt"
            var second = asset
            second.name = "second report.txt"
            let firstURL = try #require(URL(string: await media.url(for: first)))
            let secondURL = try #require(URL(string: await media.url(for: second)))
            #expect(firstURL != secondURL)
            for (url, name) in [(firstURL, "first%20report.txt"), (secondURL, "second%20report.txt")] {
                let (data, response) = try await URLSession.shared.data(from: url)
                #expect(data == bytes)
                #expect((response as? HTTPURLResponse)?.statusCode == 200)
                #expect(
                    (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.contains(name)
                        == true)
            }
            #expect(try await store.asset(id: asset.id)?.name == "storage-name.bin")
            var components = try #require(URLComponents(url: firstURL, resolvingAgainstBaseURL: false))
            let token = try #require(components.queryItems?.first(where: { $0.name == "token" })?.value)
            var fields = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            #expect(fields.count == 3)
            guard fields.count == 3 else {
                await session.stop()
                return
            }
            fields[1] = Data("tampered.txt".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
            components.queryItems = [URLQueryItem(name: "token", value: fields.joined(separator: "."))]
            let (_, changedName) = try await URLSession.shared.data(from: try #require(components.url))
            #expect((changedName as? HTTPURLResponse)?.statusCode == 404)
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @Test("OneBot resource URLs deliver bytes and reject missing, tampered, and cross-file grants")
    func resourceDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReiStore()
        let media = MediaService(assetStore: try AssetStore(directory: directory), store: store)
        let platform = PlatformService(store: store)
        let adapter = OneBotProtocolImplementation(
            version: .v12, selfID: "100", platform: platform, assetResolver: OneBotAssetResolver(media: media)
        )
        let session = ProtocolSession(
            implementation: adapter, platform: platform,
            settings: ConnectionSettings(transport: .webSocketServer, port: 0, accessToken: "private-api-token")
        )
        try await session.start()
        do {
            let bytes = Data("download through real HTTP".utf8)
            let asset = try #require(await media.store(data: bytes, name: "photo name.txt"))
            let reply = await adapter.handle(
                call: ProtocolCall(
                    name: "get_file", parameters: ["file_id": .string(asset.id), "type": "url"]
                ))
            let address = try #require(reply.data["url"]?.stringValue)
            #expect(!address.contains("private-api-token"))
            let url = try #require(URL(string: address))
            let (downloaded, response) = try await URLSession.shared.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(downloaded == bytes)
            #expect(
                (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.contains(
                    "photo%20name.txt") == true)

            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.query = nil
            let (_, missing) = try await URLSession.shared.data(from: try #require(components.url))
            #expect((missing as? HTTPURLResponse)?.statusCode == 404)
            components.queryItems = [URLQueryItem(name: "token", value: "1.invalid")]
            let (_, tampered) = try await URLSession.shared.data(from: try #require(components.url))
            #expect((tampered as? HTTPURLResponse)?.statusCode == 404)

            let other = try #require(await media.store(data: Data("other".utf8), name: "other.txt"))
            components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.path = "/assets/\(other.id)"
            let (_, crossFile) = try await URLSession.shared.data(from: try #require(components.url))
            #expect((crossFile as? HTTPURLResponse)?.statusCode == 404)
            components.path = "/assets/../private-file"
            let (_, traversal) = try await URLSession.shared.data(from: try #require(components.url))
            #expect((traversal as? HTTPURLResponse)?.statusCode == 404)
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }

    @Test("Legacy settings default resource hosting to loopback and persist an explicitly selected interface")
    func resourceHostSettings() throws {
        let legacy = try JSONDecoder().decode(ConnectionSettings.self, from: Data("{\"host\":\"192.0.2.4\"}".utf8))
        #expect(legacy.resourceHost == "127.0.0.1")
        var settings = legacy
        settings.resourceHost = "192.0.2.8"
        let restored = try JSONDecoder().decode(ConnectionSettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.resourceHost == "192.0.2.8")

        let suite = "Rei.ResourceHostTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try SettingsStorage.save(settings, defaults: defaults)
        #expect(SettingsStorage.load(defaults: defaults).resourceHost == "192.0.2.8")
    }

    @Test("Milky temp_url downloads on the API listener while API calls still require their own token")
    func milkyDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ReiStore()
        let media = MediaService(assetStore: try AssetStore(directory: directory), store: store)
        let platform = PlatformService(store: store)
        let adapter = MilkyProtocolImplementation(
            selfID: "100", platform: platform, assetResolver: MilkyAssetResolverImpl(media: media, store: store)
        )
        let session = ProtocolSession(
            implementation: adapter, platform: platform,
            settings: ConnectionSettings(transport: .milkyService, port: 0, accessToken: "milky-api-token")
        )
        try await session.start()
        do {
            let asset = try #require(await media.store(data: Data("milky bytes".utf8), name: "message.txt"))
            let baseURL = await media.baseURL
            var request = URLRequest(url: try #require(URL(string: baseURL + "/api/get_resource_temp_url")))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONValue.object(["resource_id": .string(asset.id)]).encoded()
            let (_, unauthorized) = try await URLSession.shared.data(for: request)
            #expect((unauthorized as? HTTPURLResponse)?.statusCode == 401)
            request.setValue("Bearer milky-api-token", forHTTPHeaderField: "Authorization")
            let (reply, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let body = try JSONValue.decode(from: reply)
            let address = try #require(body["data"]?["url"]?.stringValue)
            #expect(!address.contains("milky-api-token"))
            let (bytes, download) = try await URLSession.shared.data(from: try #require(URL(string: address)))
            #expect((download as? HTTPURLResponse)?.statusCode == 200)
            #expect(bytes == Data("milky bytes".utf8))
            await session.stop()
        } catch {
            await session.stop()
            throw error
        }
    }
}
