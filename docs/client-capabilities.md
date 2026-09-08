# 客户端能力与协议契约

客户端根据当前运行的协议显示操作；没有运行会话时，采用设置中选中的协议。运行中修改协议设置不会提前改变客户端能力，重新连接后才生效。协议未定义的操作入口隐藏，不发送自创扩展。

| 能力 | OneBot V11 | OneBot V12 | Milky 1.3 | 客户端入口 |
| --- | --- | --- | --- | --- |
| 回复消息 | `reply.id` | `reply.message_id`、`user_id` | `reply.message_seq` | 悬停或右键回复，编辑区显示引用，点击引用跳转 |
| 撤回消息 | `delete_msg`、`group_recall` / `friend_recall` | `delete_message`、群聊/私聊删除事件 | 分场景撤回 API、`message_recall` | 有权限时显示撤回，确认后执行 |
| 群消息表情回应 | 未定义 | 未定义 | `send_group_message_reaction`、`group_message_reaction` | 表情选择、数量、参与者提示、点击切换自己的回应 |
| 管理员变更 | `set_group_admin`、`group_admin` | 未定义 | `set_group_member_admin`、`group_admin_change` | 群成员操作菜单，仅群主可操作 |
| 成员禁言 / 解除 | `set_group_ban`、`group_ban` | 未定义 | `set_group_member_mute`、`group_mute` | 群成员菜单的 Timeout / Remove Timeout |
| 全员禁言 / 解除 | `set_group_whole_ban`、`group_ban` | 未定义 | `set_group_whole_mute`、`group_whole_mute` | 右侧 Members 面板底部 |
| 群聊戳一戳 | `notify.poke` 事件 | 未定义 | `send_group_nudge`、`group_nudge` | 消息右键 Nudge |
| 好友戳一戳 | 未纳入标准能力 | 未定义 | `send_friend_nudge`、`friend_nudge` | 私聊工具栏、消息右键 |

群成员加入、移除、好友请求等已有通路继续使用 `PlatformService`。模拟操作由所选身份发起；机器人 API 操作由当前会话的机器人身份发起。权限在平台服务验证，UI 的权限判断只用于提前隐藏或禁用入口。

## 契约来源与测试

测试预期按下面的官方定义独立编写，检查字段、类型、请求作用域及状态变化；存储幂等、身份隔离和草稿行为属于 Rei 的产品约束，不冒充协议强制要求。

- [OneBot V11 通知](https://github.com/botuniverse/onebot-11/blob/master/event/notice.md)与[消息段](https://github.com/botuniverse/onebot-11/blob/master/message/segment.md)：撤回通知和 `friend_add` 使用数值 ID，回复引用使用 `id`。
- [OneBot V12 群通知](https://12.onebot.dev/interface/group/notice-events/)、[用户通知](https://12.onebot.dev/interface/user/notice-events/)、[消息段](https://12.onebot.dev/interface/message/segments/)与[消息动作](https://12.onebot.dev/interface/message/actions/)：ID 使用字符串；群消息撤回区分发送者 `recall` 和管理员 `delete`；收到的回复包含原发送者。
- [Milky 消息 API](https://milky.ntqqrev.org/api/message)、[群聊 API](https://milky.ntqqrev.org/api/group)、[事件](https://milky.ntqqrev.org/struct/Event)与[发送消息段](https://milky.ntqqrev.org/struct/OutgoingSegment)：消息序号在会话内解析；reaction 的 `face` 与 `emoji` 是不同类型，缺省为 `face`，缺省操作为添加；撤回消息不作为可用历史返回。
- [Discord 回复](https://support.discord.com/hc/en-us/articles/360057382374-Replies-FAQ)仅作为交互参考，不作为协议行为依据。

`MessageProtocolContractTests` 覆盖协议输入输出，`MessageInteractionTests` 覆盖平台状态与事件，`ReactionMigrationTests` 从真实 V1 SwiftData 文件验证升级和重开，`ChatNavigationTests` 覆盖草稿、身份权限及协议能力。

## 状态与兼容

Reaction 与消息一起持久化，计数从参与者集合派生。重复添加、重复取消不会产生额外变化；最后一个参与者取消后移除该回应。撤回保留本地占位并清除回应，引用实时显示撤回或不可用状态。V1 数据通过 V2 轻量迁移保留。

Milky 的引用解析接口现在要求完整 `Chat`，不再维护最近会话缓存。OneBot 消息编码器接收存储依赖以补全 V12 的引用发送者。嵌入这些模块的调用方需要传入上述参数。

## 补全后的能力与验收

以下项目对应本次明确列出的补全目标；它不是三个协议全部可选接口的全覆盖声明。

| 目标 | 完整路径 | 主要验收 |
| --- | --- | --- |
| Milky 会话置顶 | `get_peer_pins` / `set_peer_pin`、`peer_pin_change`、持久状态、侧栏 Pinned 分区；包含临时会话 | `MilkyConversationContractTests`、`ConversationContentTests`；侧栏按观察状态派生 |
| Milky 已读 | `mark_message_as_read` 保存单账号、单会话的读位置；只单调推进，清空历史后重置 | `MilkyConversationContractTests`、`MilkyFileContractTests.atomicMessageState` |
| 资料点赞 | Milky `send_profile_like` 和 V11 `send_like` 保存真实计数；V11 每次和每日限额均为 10 | `MilkyConversationContractTests`、`OneBotCapabilityContractTests.profileLikes` |
| 群公告 | 创建、图片、查询、删除；权限检查、完整实体、图片可下载；客户端 Announcements 面板 | `MilkyPlatformContractTests`、`MilkyConversationContractTests`、`ConversationContentTests` |
| 群精华消息 | 设置、取消、分页、完整消息与操作者信息、`group_essence_message_change`；客户端 Highlights 面板与消息跳转 | `MilkyPlatformContractTests`、`MilkyConversationContractTests`、`ConversationContentTests` |
| Milky 文件管理 | 私聊/群上传、下载链接、文件夹列表和创建/重命名/删除、文件移动/重命名/删除/永久化；文件目录与资产字节分开建模 | `MilkyPlatformContractTests.groupFileLifecycle`、`MilkyFileContractTests`、`ConversationContentTests.fileLifecycle` |
| 私聊文件通知 | `friend_file_upload`、真实 TriSHA1、发送方向与账号范围校验；群上传继续提供 `group_file_upload` 和 V11 `group_upload` | `MilkyFileContractTests.privateFile`、`ConversationFeaturePersistenceTests.fingerprints` |
| OneBot V12 文件 | `upload_file`、`get_file`、分片上传/获取；支持 URL / path / data、HTTP 请求头、SHA256、乱序块和范围检查 | `OneBotCapabilityContractTests` |
| OneBot V11 媒体与转发 | `get_image`、`get_record`、`get_forward_msg`；完整合并转发节点、可读取文件、真实转码 | `OneBotCapabilityContractTests`、`MediaConversionTests` |
| CQ 码 | V11 字符串输入、`auto_escape`、单次实体转义、消息段参数、`raw_message` 输出 | `OneBotCapabilityContractTests.cqSyntax/cqInput/cqOutput` |
| V12 兼容性 | 独立用户/成员字段、按版本划分动作清单、标准错误码、跨机器人消息隔离 | `OneBotCapabilityContractTests.v12EntityNames/versionBoundaries/accountIsolation` |
| 群资料与申请 UI | 群改名、名片、专属头衔；发起好友/入群请求、邀请机器人；权限和协议决定可见入口 | `ConversationManagementTests` |
| 媒体 UI | 语音/视频播放、进度与音量、图片大图、文件 Quick Look 与另存为；转发展开全部节点并隔离引用范围 | `AttachmentPresentationTests`、`AttachmentLayoutTests`、`MediaConversionTests` |
| 实际资源传输 | HTTP 返回真实字节；短期签名绑定文件 ID、名称和期限，不使用 API Token 充当资源链接凭证 | `ProtocolResourceTests` |
| 持久化与并发 | V1→V2→V3 迁移；新状态重开保留；并发改名/下载不丢字段；删除后不复活；失效读标记和精华拒绝写入 | `ReactionMigrationTests`、`ConversationFeaturePersistenceTests`、`MilkyFileContractTests` |

视觉沿用 macOS 的系统侧栏材质与 Liquid Glass。左右辅助栏的材质连续覆盖顶部、列表和底部区域，列表不再单独铺设灰底；浮动输入区、发送按钮、会话工具和事件筛选保留玻璃效果。浅色、深色及窗口激活状态由系统处理。

主窗口采用左侧导航、中央聊天、右侧检查器。左栏顶部提供新建与搜索，底部固定连接状态、设置和当前发言身份。右栏通过 Conversation / Events 页签切换会话工具与协议流量；可收起和调整宽度，事件列表与 JSON 详情之间的分隔线也可拖动。

Conversation 内提供 Overview、Members、Files、Announcements、Highlights、Settings；按当前协议与会话类型筛选。成员、资料和共享内容直接在右栏操作，新建内容或提交请求仍使用独立编辑弹窗。V11 只显示其支持的上传事件和资料点赞等入口；V12 保留基础资料与成员列表，隐藏协议未定义的管理操作。切换会话会重建对应编辑状态；切换协议时，失效的栏目自动返回 Overview。聊天草稿继续按会话与发言身份独立保存。

`WorkspaceLayoutTests` 检查协议栏目边界，并用填充数据渲染 320 点宽的工具面板、980 / 1320 点宽的浅色和深色窗口。输入区采用上方文本、下方附件与发送操作的布局，避免横向挤压文本编辑区。

文件名属于共享文件条目，文件哈希属于不可变字节。同一内容以不同名称上传、或条目改名后，各自的签名下载链接仍保留正确名称。目录中的下载次数记录有效下载请求的发起，不将后续网络传输失败当成平台可观测的完成事件。

V11 每日点赞额度以模拟器的 UTC 日期计数，累计计数独立保留。默认上传文件为永久文件；带过期时间的模拟文件可以通过永久化接口清除有效期。群、用户或消息被删除时，其从属状态同步清理。

## 内置媒体转换与构建

QQ SILK 由固定源码版本的内置 C 解码器转为 PCM/WAV；其他音视频格式使用随应用分发的 FFmpeg 9.0.1。客户端和 OneBot `get_record` 共用 `MediaConversionService`，不依赖运行机器的 Homebrew，也不对协议输入执行 shell 命令。

`make test` 使用源码构建的媒体工具验证 mp3、amr、wma、m4a、spx、ogg、wav、flac 往返以及视频转码；`make build` / `make archive` 同样准备匹配架构的产物。应用包含 FFmpeg 源码归档、构建配置和许可证，并通过 Xcode Copy Files / CodeSignOnCopy 嵌入。发布检查见 [RELEASING.md](../RELEASING.md)。

OneBot 使用独立资源 HTTP 监听端口。Resource Host 默认 `127.0.0.1`；机器人运行在另一台机器时，应设置为它可达的本机接口地址。Milky 在同一个 API 监听端口提供资源下载。

本次新增的官方依据：[Milky 系统 API](https://milky.ntqqrev.org/api/system)、[Milky 文件 API](https://milky.ntqqrev.org/api/file)、[群公告实体](https://milky.ntqqrev.org/struct/GroupAnnouncementEntity)、[精华消息实体](https://milky.ntqqrev.org/struct/GroupEssenceMessage)、[OneBot V12 文件动作](https://12.onebot.dev/interface/file/actions/)、[OneBot V11 API](https://github.com/botuniverse/onebot-11/blob/master/api/public.md)。

未引入非标准 OneBot reaction 扩展。V11 匿名管理等其他未列出的接口，以及 V12 Guild/Channel 等非当前 QQ 会话模型能力，仍不能视为已经实现。没有将 Discord 的编辑、线程等交互强行映射为协议不存在的事件。
