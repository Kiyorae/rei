# Client Capabilities and Protocol Contracts

The client exposes operations supported by the running protocol. With no active session, it uses
the protocol selected in settings. Changing settings during a session takes effect after
reconnecting. Operations absent from a protocol are hidden; Rei does not invent wire extensions.

| Capability | OneBot V11 | OneBot V12 | Milky 1.3 | Client entry point |
| --- | --- | --- | --- | --- |
| Reply | `reply.id` | `reply.message_id`, `user_id` | `reply.message_seq` | Hover or context-menu reply; composer preview; click a reference to navigate |
| Recall | `delete_msg`, `group_recall` / `friend_recall` | `delete_message`, group/private deletion events | Context-specific recall APIs, `message_recall` | Available with permission; requires confirmation |
| Group reactions | Not defined | Not defined | `send_group_message_reaction`, `group_message_reaction` | Emoji picker, counts, participant tooltips, and toggling your reaction |
| Administrator changes | `set_group_admin`, `group_admin` | Not defined | `set_group_member_admin`, `group_admin_change` | Group member menu; owner only |
| Member mute/unmute | `set_group_ban`, `group_ban` | Not defined | `set_group_member_mute`, `group_mute` | Timeout / Remove Timeout in the member menu |
| Group-wide mute/unmute | `set_group_whole_ban`, `group_ban` | Not defined | `set_group_whole_mute`, `group_whole_mute` | Bottom of the Members panel |
| Group nudge | `notify.poke` event | Not defined | `send_group_nudge`, `group_nudge` | Message context menu: Nudge |
| Friend nudge | Not included as a standard capability | Not defined | `send_friend_nudge`, `friend_nudge` | Private conversation toolbar and message context menu |

Membership changes, friend requests, and other simulated actions pass through `PlatformService`.
Operator actions use the selected identity; bot API actions use the active session's bot identity.
The platform service enforces permissions. UI checks only hide or disable unavailable actions early.

## Contract References and Tests

Contract tests check fields, types, request scope, and state transitions against the protocol
references below. Storage idempotency, identity isolation, and draft behavior are Rei product
constraints, not protocol requirements.

- OneBot V11 [notices](https://github.com/botuniverse/onebot-11/blob/master/event/notice.md) and
  [message segments](https://github.com/botuniverse/onebot-11/blob/master/message/segment.md): recall
  notices and `friend_add` use numeric IDs; replies use `id`.
- OneBot V12 [group notices](https://12.onebot.dev/interface/group/notice-events/),
  [user notices](https://12.onebot.dev/interface/user/notice-events/),
  [message segments](https://12.onebot.dev/interface/message/segments/), and
  [message actions](https://12.onebot.dev/interface/message/actions/): IDs are strings; group
  deletion distinguishes sender `recall` from administrator `delete`; incoming replies identify
  the original sender.
- Milky [message APIs](https://milky.ntqqrev.org/api/message),
  [group APIs](https://milky.ntqqrev.org/api/group), [events](https://milky.ntqqrev.org/struct/Event),
  and [outgoing segments](https://milky.ntqqrev.org/struct/OutgoingSegment): message sequences are
  resolved within a conversation; reaction types distinguish `face` from `emoji`, default to
  `face`, and default to adding a reaction; recalled messages are unavailable as history.
- [Discord replies](https://support.discord.com/hc/en-us/articles/360057382374-Replies-FAQ) are an
  interaction reference only, not a protocol authority.

`MessageProtocolContractTests` covers protocol input and output; `MessageInteractionTests` covers
platform state and events; `ReactionMigrationTests` verifies migration and reopening from real V1
SwiftData files; `ChatNavigationTests` covers drafts, identity permissions, and protocol capabilities.

## State and Compatibility

Reactions persist with messages, with counts derived from participant sets. Repeated additions or
removals are idempotent; removing the last participant removes the reaction. Recall preserves a
local placeholder and clears reactions. Reply references reflect recalled or unavailable messages.
V1 data is preserved through the V2 lightweight migration.

Milky reply resolution requires a complete `Chat` rather than a recent-conversation cache. OneBot
message encoders receive storage access to resolve the V12 reply sender. Callers embedding these
modules must supply those dependencies.

## Implemented Features and Verification

This table describes the implemented feature paths and their tests. It does not claim coverage of
all optional interfaces in the three protocols.

| Feature | Implementation scope | Primary tests |
| --- | --- | --- |
| Milky conversation pins | `get_peer_pins`, `set_peer_pin`, `peer_pin_change`, persistent state, and the sidebar Pinned section; includes temporary conversations | `MilkyConversationContractTests`, `ConversationContentTests` |
| Milky read positions | `mark_message_as_read` stores a position per account and conversation; advances monotonically and resets when history is cleared | `MilkyConversationContractTests`, `MilkyFileContractTests.atomicMessageState` |
| Profile likes | Milky `send_profile_like` and V11 `send_like` persist counts; V11 enforces per-call and daily limits of 10 | `MilkyConversationContractTests`, `OneBotCapabilityContractTests.profileLikes` |
| Group announcements | Create, query, and delete; permission checks, complete entities, downloadable images, and the Announcements panel | `MilkyPlatformContractTests`, `MilkyConversationContractTests`, `ConversationContentTests` |
| Group highlights | Set, unset, paginate, and return complete message/operator details; `group_essence_message_change`, Highlights panel, and message navigation | `MilkyPlatformContractTests`, `MilkyConversationContractTests`, `ConversationContentTests` |
| Milky file management | Private/group uploads, download URLs, folder listing/creation/renaming/deletion, and file moving/renaming/deletion/permanence; directory entries are separate from asset bytes | `MilkyPlatformContractTests.groupFileLifecycle`, `MilkyFileContractTests`, `ConversationContentTests.fileLifecycle` |
| Private file notifications | `friend_file_upload`, actual TriSHA1 fingerprints, direction and account checks; group uploads emit `group_file_upload` and V11 `group_upload` | `MilkyFileContractTests.privateFile`, `ConversationFeaturePersistenceTests.fingerprints` |
| OneBot V12 files | `upload_file`, `get_file`, fragmented upload/retrieval; URL/path/data sources, HTTP headers, SHA-256, out-of-order chunks, and range checks | `OneBotCapabilityContractTests` |
| OneBot V11 media and forwards | `get_image`, `get_record`, `get_forward_msg`; complete merged-forward nodes, readable files, and media conversion | `OneBotCapabilityContractTests`, `MediaConversionTests` |
| CQ codes | V11 string input, `auto_escape`, single-pass entity escaping, segment parameters, and `raw_message` output | `OneBotCapabilityContractTests.cqSyntax/cqInput/cqOutput` |
| V12 compatibility | Separate user/member fields, version-specific action lists, standard errors, and message isolation between bots | `OneBotCapabilityContractTests.v12EntityNames/versionBoundaries/accountIsolation` |
| Group management and request UI | Group names, member cards, titles, friend/join requests, and bot invitations; visibility follows permissions and protocol capabilities | `ConversationManagementTests` |
| Media UI | Audio/video playback, progress and volume, full-size images, Quick Look and Save As; all forward nodes expand with isolated reply scopes | `AttachmentPresentationTests`, `AttachmentLayoutTests`, `MediaConversionTests` |
| Resource delivery | HTTP serves actual bytes; short-lived signatures bind file ID, name, and expiry without using API tokens as download credentials | `ProtocolResourceTests` |
| Persistence and concurrency | V1 → V2 → V3 migrations, reopening persisted state, concurrent rename/download updates, no resurrection after deletion, and rejection of stale read positions or highlights | `ReactionMigrationTests`, `ConversationFeaturePersistenceTests`, `MilkyFileContractTests` |

## Workspace and Conversation Tools

The main window has navigation on the left, chat in the center, and an inspector on the right.
The sidebar places creation and search controls at the top, with connection status, settings, and
the current speaking identity at the bottom. The inspector switches between **Conversation** and
**Events**, can be collapsed or resized, and has a draggable divider between event lists and JSON
details.

Conversation tools include Overview, Members, Files, Announcements, Highlights, and Settings,
filtered by protocol and conversation type. Members, profiles, and shared content are managed in
the inspector; creation and request submission use separate editing sheets. V11 exposes supported
upload notifications and profile likes. V12 retains basic profiles and member lists while hiding
undefined management operations. Changing conversations recreates editing state; changing protocols
returns unavailable sections to Overview. Drafts remain separate per conversation and speaking identity.

System sidebar materials span the full height of both auxiliary columns. The floating composer,
send button, conversation tools, and event filters use Liquid Glass. macOS handles light/dark
appearance and window activation. The composer places text above attachment and send controls to
preserve editing space.

`WorkspaceLayoutTests` checks protocol-specific sections and renders populated 320-point tool
panels and 980/1320-point windows in light and dark appearances.

## File and Account State

File names belong to shared-file entries; hashes describe immutable bytes. Identical content
uploaded under different names, or renamed entries, retains the correct names in signed download
URLs. Download counts record valid download requests starting, not successful completion of a later
network transfer.

V11 daily like quotas use the simulator's UTC date; cumulative counts persist independently.
Uploads are permanent by default. Simulated expiring files can be made permanent by clearing their
expiry through the corresponding API. Deleting groups, users, or messages cleans up dependent state.

## Media Conversion and Resource Hosting

A bundled C decoder converts QQ SILK to PCM/WAV. Other audio/video conversion uses bundled
FFmpeg, pinned in [`media-dependencies.lock`](../script/media-dependencies.lock). The client and
OneBot `get_record` share `MediaConversionService`, without requiring Homebrew or running protocol
input through a shell.

`make test` prepares media tools from source and tests mp3, amr, wma, m4a, spx, ogg, wav, and flac
round trips and video conversion. `make build` and `make archive` prepare matching architecture
artifacts. Xcode embeds the executable through Copy Files / CodeSignOnCopy, and the app includes
source archives, build configuration, and licenses. See [RELEASING.md](../RELEASING.md).

OneBot serves resources through a separate HTTP listener. Resource Host defaults to `127.0.0.1`;
for a bot on another machine, select a local interface address reachable by that bot. Milky serves
resource downloads on its API listener.

Additional protocol references: [Milky system APIs](https://milky.ntqqrev.org/api/system),
[Milky file APIs](https://milky.ntqqrev.org/api/file),
[group announcements](https://milky.ntqqrev.org/struct/GroupAnnouncementEntity),
[group highlights](https://milky.ntqqrev.org/struct/GroupEssenceMessage),
[OneBot V12 file actions](https://12.onebot.dev/interface/file/actions/), and
[OneBot V11 APIs](https://github.com/botuniverse/onebot-11/blob/master/api/public.md).

## Limits

Rei does not introduce nonstandard OneBot reaction extensions. Unlisted operations such as V11
anonymous administration, and V12 Guild/Channel capabilities outside the current QQ conversation
model, must not be assumed implemented. Interactions such as Discord message editing and threads
are not mapped onto events absent from these protocols.
