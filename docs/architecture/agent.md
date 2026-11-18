# 应用内校园 Agent

Android 在 Agent 栏提供流式聊天。打开「模型设置」，选择 OpenAI 兼容 Chat Completions 或 Anthropic Messages，填写 HTTPS API 前缀和密钥。应用会读取服务提供的模型 ID 列表，也可以手动填写模型 ID。官方前缀分别为 `https://api.openai.com/v1` 和 `https://api.anthropic.com/v1`。兼容服务需支持相应协议的 SSE 和工具调用。模型及搜索密钥保存在由 Android Keystore 保护的加密存储中。

消息框旁的模型按钮可以直接切换模型。显示名称取自服务商返回的 `name` 或 `display_name`，实际请求使用原始 ID。右上角「对话历史」支持按标题搜索、恢复、重命名和删除。历史按校园账号加密保存，未登录时使用独立的访客空间。每个账号最多保存 100 个对话，单个对话最多 220 KiB。

在消息旁点「添加附件」，选择 PDF、PNG、JPEG、WebP 或 UTF-8 文本（含 Markdown、CSV、JSON）。选中「课程文件」后也可以让 Agent 读取当前账号可访问的 Canvas PDF，包括作业说明中链接到的课程文件。两类附件每轮合计最多 3 个、总计 2 MiB，单个文本文件最多 24 KiB。课程文件复用现有的 Core 下载产物，模型设置中可清理当前账号的课程文件缓存。

打开「搜索网页」后，可以通过当前模型服务联网搜索。使用 OpenAI Responses、Anthropic Messages 或 DeepSeek 官方搜索接口所支持的协议。也可以配置 Brave Search 密钥，改用 Brave Search。聊天会列出实际检索到的网页标题和链接。[OpenAI 网页搜索](https://developers.openai.com/api/docs/guides/tools-web-search)、[Claude 网页搜索](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)、[DeepSeek 网页搜索](https://api-docs.deepseek.com/zh-cn/api/search/)、[Brave Search API](https://api-dashboard.search.brave.com/app/documentation/web-search)

## 数据与执行边界

- [会话和工具注册表](../../apps/dansheng_app/lib/agent/agent_session.dart)使用纯 Dart。模型适配器把工具名称、说明及 JSON Schema 转为对应协议的函数声明，收集完整的流式调用后交由会话执行。会话限制输入、查询次数和工具响应大小，按照当前账号、信息源选择与用户授权决定可用工具。
- [校园工具](../../apps/dansheng_app/lib/agent/campus_tools.dart)定义固定的 Core 方法与返回字段，覆盖 Canvas 课程与作业、复旦树洞（旦挞茶楼）、教务公告和图书馆客流。院系通知和科研动态使用 App 接入的复旦公开官网列表。帖子、课程和作业链接打开对应页面，返回后继续原对话。
- [Android 接入](../../apps/dansheng_app/lib/ui/campus/agent/agent_tools.dart)通过 `CampusApi`、Pigeon 和原生校园服务调用 Core，复用账号绑定、认证恢复、树洞同意状态与缓存。校园工具在当前账号下执行固定的读操作。
- 信息源默认关闭。确认提示提供本次允许和始终允许。长期授权绑定账号、模型地址和信息源，可在聊天框旁的「管理授权」撤销。历史保留消息、附件名和来源链接。恢复会话或切换模型时，只沿用发送至同一服务的普通对话上下文。工具结果和附件内容仅用于原轮次。

## 桌面与 MCP

Windows、macOS 或 Linux 客户端可复用 Dart 会话、模型适配器和校园工具注册表，为注册表注入桌面 Core 客户端及平台凭据存储。Android 通过应用内 Function Calling 执行校园工具，使用已有的 App 桥接。

Rust [Core Host](../../core/crates/dansheng-host/src/mcp.rs)已有 stdio MCP 适配器，并按专用客户端身份与授权调度 Core 的校园读方法。未来 Headless 入口可沿用相同的 Core 方法和权限检查，在 Host 侧提供客户端可见的工具清单，并按需要增加经过鉴权的 Streamable HTTP 传输。校园业务、认证和缓存继续由 Core 与平台服务负责。Android 已有的回环配对入口仍可在「本地检索与配对」中访问。
