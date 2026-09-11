# Rei for macOS

[![CI](https://github.com/Kiyorae/rei/actions/workflows/ci.yml/badge.svg)](https://github.com/Kiyorae/rei/actions/workflows/ci.yml)

> [!WARNING]
> Rei is under active development. It does not yet fully represent the capabilities or behavior of
> the supported protocols and must not be treated as a complete protocol specification or a
> production-parity implementation.

Rei is a development tool that simulates a chat platform. It presents itself as QQ: the bot
framework under test connects to it as if it were a real platform, while you use the app to send
messages as any identity, create groups, and send friend requests. The framework receives the same
events and action responses it would receive in production. No real account is required, there is no
risk-control system to worry about, and you do not need another person to help reproduce an issue.

## Project Provenance

Rei's inspiration and original design come from the upstream
[project by Akirami](https://github.com/A-kirami/matcha). Rei is an independent native macOS
implementation: the upstream project uses Vue and Tauri, while Rei uses AppKit and
uses Apple system frameworks alongside bundled media codecs.

## Releases

[GitHub Releases](https://github.com/Kiyorae/rei/releases) provide Universal 2 ZIP and
DMG downloads for macOS 26 or later. Published application bundles are signed with Developer ID,
notarized by Apple, stapled for offline Gatekeeper verification, and accompanied by SHA-256
checksums and GitHub build provenance. See [RELEASING.md](RELEASING.md) for the complete trust and
recovery model.

### Developer Builds

[CI runs](https://github.com/Kiyorae/rei/actions/workflows/ci.yml) provide a
`Rei-developer-<commit>` artifact after the Release Build job succeeds, including manual runs.
These Universal 2 builds require no Apple signing credentials and are retained for 14 days.
They use ad-hoc signatures for local execution, with no Developer ID signature or notarization.

Download and extract the Actions artifact, verify the enclosed ZIP with `shasum -a 256 -c
SHA256SUMS`, then extract that ZIP and move `Rei.app` to Applications. GitHub requires signing in
to download Actions artifacts. If macOS blocks the app, attempt to open it once, then use
**System Settings > Privacy & Security > Open Anyway** for this app only, after checking the
source commit. See [developer packaging](RELEASING.md#developer-packaging) for local builds.

## Supported Protocols

- OneBot V11, with forward and reverse WebSocket connections
- OneBot V12, with forward and reverse WebSocket connections
- Milky 1.3, with its HTTP API, `/event` WebSocket, and optional WebHook event sinks

Rei is the simulated messaging platform and implements the protocol-facing endpoint. It does not
provide a NoneBot adapter plugin. `nonebot-adapter-onebot` and `nonebot-adapter-milky` are consumers:
they call Rei's protocol endpoints and receive the events Rei produces. OneBot dispatches by
the `action` field over a persistent connection, while Milky dispatches API calls by URL path over
HTTP. All simulated state remains in Rei.

## Connecting NoneBot

OneBot defines forward and reverse connections from the perspective of the **protocol
implementation**. Rei is the protocol implementation here:

| Mode | Rei role | NoneBot role and configuration |
| --- | --- | --- |
| Forward WebSocket | Server; waits for a connection | Use a `WebSocketClient` driver. Point V11 `ONEBOT_WS_URLS` or V12 `ONEBOT_V12_WS_URLS` at Rei. |
| Reverse WebSocket (recommended) | Client; initiates the connection | V11 uses `ReverseDriver`; V12 uses an ASGI driver such as `DRIVER=~fastapi`. Rei connects to NoneBot's listening address. |

For a reverse connection, select **WebSocket Client (Reverse Connection)** in Rei and enter
NoneBot's `HOST`, `PORT`, and the appropriate path:

- OneBot V11: `/onebot/v11/ws`
- OneBot V12: `/onebot/v12/ws`

For example, if NoneBot listens on `127.0.0.1:8080`, the full V12 address is
`ws://127.0.0.1:8080/onebot/v12/ws`. If NoneBot has an Access Token configured, enter the same value
in Rei. When the two processes run in different containers, virtual machines, or hosts, do not
use `127.0.0.1` to address the other process. Use a service name or address that Rei can actually
reach. See the [NoneBot OneBot connection guide](https://onebot.adapters.nonebot.dev/docs/guide/setup/)
for the complete configuration.

### Milky

Milky is one protocol service rather than a choice between mutually exclusive connection modes.
Starting it always exposes these endpoints on Rei's configured `host:port`:

- `http://host:port/api/<action>`: API called by consumers
- `ws://host:port/event`: event stream consumed over WebSocket

NoneBot's `nonebot-adapter-milky` can consume `/event` with `MILKY_CLIENTS`. For example, if Rei
listens on `127.0.0.1:5700`:

```dotenv
DRIVER=~aiohttp+~fastapi
MILKY_CLIENTS='[{"host":"127.0.0.1","port":"5700","access_token":"the same Token as Rei","secure":false}]'
```

WebHooks are optional additional event sinks; adding one does not disable `/event`. To exercise
NoneBot's `MILKY_WEBHOOK` consumer, add `http://127.0.0.1:8080/milky/` under Rei's **Event
WebHooks**, then configure NoneBot with:

```dotenv
DRIVER=~aiohttp+~fastapi
MILKY_WEBHOOK='{"host":"127.0.0.1","port":"5700","access_token":"the same Token as Rei","secure":false}'
```

The `MILKY_WEBHOOK` host and port point back to Rei's API listener; they are not NoneBot's own
listening address. The configured token is used for API requests, `/event` connections, and WebHook
delivery. Rei can serve `MILKY_CLIENTS` consumers and any number of WebHook destinations at the
same time. A consumer attached through both routes receives the same event twice, so that topology
should be intentional. The app reports **Serving** as soon as the API and event service is ready; it
does not wait for a consumer to connect before allowing simulated messages.

## Architecture

See [Client Capabilities and Protocol Contracts](docs/client-capabilities.md) for available
operations, protocol-specific behavior, persistence guarantees, and test coverage.

- `ReiCore` contains the domain model and storage. Users, groups, and messages are persisted with
  SwiftData, while media uses content-addressed file storage. This module knows nothing about any
  wire protocol.
- `ReiTransport` is the transport layer. Its WebSocket server and client and minimal HTTP/1.1
  server are all built on Network.framework.
- `ReiProtocol` contains the protocol-neutral translation/session boundary and `PlatformService`.
- `ReiOneBot` and `ReiMilky` implement the protocol endpoints consumed by framework adapters.
- `ReiLogging` provides typed application diagnostics written to OSLog, rotating JSON Lines files,
  and a bounded in-memory window. Log events cannot contain access tokens, message bodies, or raw
  protocol payloads.
- `ReiUI` provides the AppKit interface, including a dedicated application log
  console. Raw protocol traffic remains available in a separate inspector.
- `App/ReiApplication.swift` 启动原生应用，并将生命周期、窗口和菜单管理交给
  `ReiUI` 中的 `ReiApplicationDelegate`；其余实现保留在 SwiftPM 模块中。

The key invariant lives in `PlatformService`: every state change passes through it, whether it was
triggered by a person pressing Send in the app or by a framework calling `send_group_message`.
Because both paths converge there, a connected framework cannot distinguish activity it caused from
activity initiated by the operator. This is what makes the simulation credible. Protocol encoders
subscribe to the event stream and never write state directly.

## Application Log Console

Open the standalone console with **Window > Log Console** (`⌥⌘L`). It supports searching and
filtering by event, level, and category; viewing and copying structured details; and clearing or
exporting the complete history. The in-memory window retains up to 1,000 records from the current
process. On-disk logs live in the application cache directory and use a 5 MiB active file with up to
five rotated files. Every export creates a unique directory at the chosen location containing raw
JSON Lines records and a structured summary, without overwriting previous exports.

## Build and Run

### Demo Mode

```sh
./script/build_and_run.sh --demo
./script/build_and_run.sh --debug --demo
```

Demo mode uses an isolated in-memory database, preferences, and media cache with one group chat
and one private conversation. It simulates a message or state change every four seconds and
repeats the sequence after approximately two minutes. Switching conversations or scrolling manually
pauses playback; the **Demo** menu controls playback and automatic scrolling. The demo never opens
the normal chat database and does not require an external bot.

An embedded Milky client connects to a local service on an automatically assigned `127.0.0.1`
port using a token generated for each connection. The sidebar reports the actual `get_login_info`
API round-trip time every four seconds. Click the connection status to disconnect or reconnect.
Pausing playback keeps the protocol connected; closing the demo window stops both client and service.

The showcase includes multilingual text, mentions, replies, images, animated GIFs, audio, video,
files, nested forwards, recalls, group reactions, announcements, shared files, highlights, and
profile likes. Raw Events displays the embedded client's actual API requests and event traffic.
The Akame artwork appears in avatars and image messages; its animated variant respects Reduce Motion.

Assets are bundled from `Sources/ReiUI/Resources/Showcase`. Run `make showcase-media` to regenerate
the animated GIF, sound, and video using ImageIO and the bundled FFmpeg build.

### Prerequisites

- macOS 26 or later to run Rei; macOS 26.2 or later for the recommended development toolchain.
- A full installation of Xcode 26.6 or newer with the macOS 26 SDK. Command Line Tools alone do not
  include the complete SDK and Swift compiler plugins required by this project.
- Optionally, install `xcodes` to select the repository's recommended stable Xcode version.

### Select the Xcode Toolchain

With `xcodes` installed, run the following commands from the repository root:

```sh
xcodes select
xcodebuild -version
```

`xcodes select` reads `.xcode-version`, which records the recommended stable toolchain rather than an
exact build requirement. Newer Xcode versions are accepted by the repository checks. Without
`xcodes`, select any compatible full Xcode under **Xcode > Settings > Locations > Command Line
Tools**, or set its path for the current shell:

```sh
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
xcodebuild -version
```

If `xcodebuild` reports `/Library/Developer/CommandLineTools` as the active developer directory,
the standalone Command Line Tools are still selected. Select the full Xcode installation before
continuing.

`make quality` checks capabilities rather than exact identity: Xcode must be at least 26.6, expose a
macOS 26 or newer SDK, and understand the Swift 6.2 package manifest. Xcode 27 and later can
therefore be used for forward-compatibility testing without changing repository metadata.

### Build and Run with Xcode

Prepare the bundled media tools, then open the project with the selected Xcode installation:

```sh
make media-tools
xed Rei.xcodeproj
```

Select the shared `Rei App` scheme and the `My Mac` destination, then choose
**Product > Run** (`⌘R`). The Xcode application target is the sole source of the `.app` bundle,
Info.plist, resources, signing, and archives. `Package.swift` defines the Swift modules and package
tests used by the application, so `swift run` does not produce a runnable Rei app.

### Build and Run from the Command Line

Build and launch a Debug app for the host architecture, then verify that its process started:

```sh
./script/build_and_run.sh --verify
```

The script prepares the media tools through `make build`, asks any running Rei process to exit,
and launches `.build/xcode/Build/Products/Debug/Rei.app`. Use `--debug` to launch under LLDB or
`--logs` to stream application logs.

To build without launching, use the repository targets:

```sh
make build BUILD_CONFIGURATION=Debug BUILD_ARCHS="$(uname -m)"
make build
```

The second command produces an unsigned Universal 2 Release app at
`.build/xcode/Build/Products/Release/Rei.app`. Both commands prepare the required media tools and
use the shared Xcode scheme. Local builds do not require an Apple Developer account. Distribution
builds use the protected release workflow; see [RELEASING.md](RELEASING.md) for signing,
notarization, packaging, and recovery details.

App Sandbox is currently disabled because protocol clients may provide arbitrary local absolute
paths for message attachments. A sandboxed app cannot read those paths without user-mediated
authorization. Supporting Mac App Store distribution would therefore require redesigning the file
transfer contract rather than merely enabling the sandbox.

## Quality Checks

The repository uses `swift format` from the selected Xcode toolchain. Its complete rule set is
checked into `.swift-format`. Run the unified quality gate from the repository root:

```sh
./script/check.sh
```

The script runs strict formatting checks, the SwiftPM test suite with warnings treated as errors,
and a complete macOS application build with warnings treated as errors. It stops at the first
failure.

The same layers can be run independently through the repository Makefile:

```sh
make quality
make test
make build
make analyze
```

To apply formatting changes, run:

```sh
make format
```

The command lists source roots explicitly to avoid generated files under `.build`. Run
`./script/check.sh` again after formatting.

## Testing

```sh
make test
```

The test suite lives in SwiftPM to preserve white-box access to package internals. `make test`
first builds the host-architecture media tools, then runs `swift test` with warnings treated as
errors and `REI_TEST_FFMPEG` pointing to the prepared executable. It does not produce an `.app` bundle. Ensure that
`xcode-select` or `DEVELOPER_DIR` points to the full Xcode installation before running it.

Live interoperability tests against a real `nonebot-adapter-milky` process are disabled by
default. Enable them by setting `REI_LIVE_MILKY_API_PORT`, `REI_LIVE_MILKY_TOKEN`, and
`REI_LIVE_MILKY_SELF_ID`. WebHook scenarios also require `REI_LIVE_MILKY_WEBHOOK_URL`;
WebSocket scenarios require `REI_LIVE_MILKY_EXPECT_WEBSOCKET=1`. These runtime values are never
written to the repository.

## Dependencies

Swift 包通过 MarkdownView 及其传递依赖提供 Markdown 渲染。持久化使用 SwiftData，
界面使用 AppKit；网络、加密与文件类型识别分别使用 Network.framework、CryptoKit
和 UniformTypeIdentifiers。

Media conversion uses the vendored SILK C decoder and a bundled FFmpeg executable built with
LAME, OpenCORE AMR, and Speex. Versions and source checksums are pinned in
[`script/media-dependencies.lock`](script/media-dependencies.lock); pkgconf is built as a build-time
tool. The first media build requires network access to download upstream sources. No Homebrew
installation is required. See [bundled media tools](RELEASING.md#bundled-media-tools) and the
[SILK notice](Sources/CSilk/NOTICE.md) for source, build, and licensing details.

## 原生聊天与 Markdown

聊天列表使用 AppKit `NSTableView` 管理消息复用、滚动与入场动画，三栏工作区使用
`NSSplitViewController`。消息正文通过 AppKit MarkdownView 显示标题、列表、引用、
强调、链接、代码高亮、表格和数学公式；存储、协议发送和 Copy Text 保留原始 Markdown。
网页和邮件链接可点击打开。聊天仍使用 Rei 自己的图片、音视频和文件附件。

新消息、发送反馈、回应计数、附件与提及以及检查器切换包含动效，并遵循 macOS
“减少动态效果”设置。首次加载历史不播放入场动画，浏览历史时新消息不抢走阅读位置。

MarkdownView 与相关 Swift 包由 `Package.resolved` 固定版本；许可证位于
[`Resources/Licenses`](Sources/ReiUI/Resources/Licenses)，也可从 About 页面查看。
设计与验收边界见 [UI 改造说明](docs/ui-modernization.md)。

## License

Rei for macOS is distributed under the [GNU Affero General Public License v3.0](LICENSE). The
[upstream project's](#project-provenance) code is Copyright © 2023 Akirami and is licensed under the
GNU AGPL v3.0; its logo is separately licensed under CC BY-NC-ND.

## Contributing and Support

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development and pull-request workflow,
[SUPPORT.md](SUPPORT.md) for public support requests, and [SECURITY.md](SECURITY.md) for private
vulnerability reporting and the repository's security boundaries.
