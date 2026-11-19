# 应用内校园 Agent

Android 在 Agent 栏提供流式聊天。打开「模型设置」，选择 OpenAI 兼容 Chat Completions、OpenAI Responses 或 Anthropic Messages，再填写 HTTPS API 前缀和密钥。OpenAI 官方前缀为 `https://api.openai.com/v1`，Anthropic 官方前缀为 `https://api.anthropic.com/v1`。DeepSeek 官方 Responses 使用 `https://api.deepseek.com`，可选模型 `deepseek-flash`。应用会读取模型列表，也可以手动填写模型 ID。兼容服务需支持对应协议的 SSE 和工具调用。模型及搜索密钥保存在由 Android Keystore 保护的加密存储中。

输入区可以切换模型、选择默认／低／中／高推理强度和开关联网搜索。显示名称取自服务商返回的 `name` 或 `display_name`，实际请求使用原始 ID。支持推理档位的 API 会收到对应参数。回答以 Markdown 渲染，支持 LaTeX 公式与可复制的代码块。可以复制回答，或对最近一条纯文本提问编辑后重发、重新生成。输出达到模型上限时，Agent 会自动尝试接续一次。右上角「对话历史」支持按标题搜索、恢复、重命名和删除。历史按校园账号加密保存，未登录时使用独立的访客空间。每个账号最多保存 100 个对话，单个对话最多 220 KiB。

在输入区点「+」可附加本地文件或云端文件、选择信息源及管理授权。云端选择器可从 eLearning 或复旦云盘选择文件，先加入草稿，发送时再进行附件授权。开启「课程文件」或「复旦云盘」信息源后，支持工具调用的模型还可按需查询文件。支持 PDF、PNG、JPEG、WebP 和 UTF-8 文本（含 Markdown、CSV、JSON）。

Core 先验证课程文件的访问范围或云盘目录权限，再使用同一套受管文件机制缓存下载，缓存按账号、会话和文件版本区分。可在模型设置里清理当前账号的两类本地缓存。Core 下载上限为 200 MiB。Agent 发送完整附件，UTF-8 文本上限为 24 KiB，图片上限为 2 MiB。校园 PDF 原件可内联发送至支持 PDF 的模型，内联上限为 8 MiB。DeepSeek 官方文件接口支持上传 100 MiB 以内的校园 PDF 原件，超过内联上限的 PDF 直接从缓存流式上传。DeepSeek 在服务端按丰富版面解析 PDF。每轮最多发送 3 个附件。

打开「搜索网页」后，可以通过当前模型服务联网搜索。使用 OpenAI Responses、Anthropic Messages 或 DeepSeek 官方搜索接口所支持的协议。也可以配置 Brave Search 密钥，改用 Brave Search。聊天会列出实际检索到的网页标题和链接。[OpenAI 网页搜索](https://developers.openai.com/api/docs/guides/tools-web-search)、[Claude 网页搜索](https://platform.claude.com/docs/en/agents-and-tools/tool-use/web-search-tool)、[DeepSeek 网页搜索](https://api-docs.deepseek.com/zh-cn/api/search/)、[Brave Search API](https://api-dashboard.search.brave.com/app/documentation/web-search)

## 数据与执行边界

- [会话和工具注册表](../../apps/dansheng_app/lib/agent/agent_session.dart)使用纯 Dart。模型适配器把工具名称、说明及 JSON Schema 转为对应协议的函数声明，收集完整的流式调用后交由会话执行。会话限制输入、查询次数和工具响应大小，按照当前账号、信息源选择与用户授权决定可用工具。
- [校园工具](../../apps/dansheng_app/lib/agent/campus_tools.dart)定义固定的 Core 方法与返回字段，覆盖 Canvas 课程与作业、复旦树洞（旦挞茶楼）、教务公告和图书馆客流。院系通知和科研动态使用 App 接入的复旦公开官网列表。帖子、课程和作业链接打开对应页面，返回后继续原对话。
- [Android 接入](../../apps/dansheng_app/lib/ui/campus/agent/agent_tools.dart)通过 `CampusApi`、Pigeon 和原生校园服务调用 Core，复用账号绑定、认证恢复、树洞同意状态与缓存。校园工具在当前账号下执行固定的读操作。
- 信息源默认关闭。确认提示提供本次允许和始终允许。长期授权绑定账号、模型地址和信息源，可在输入框「+」菜单的「管理授权」撤销。历史保留消息、附件名和来源链接。同一账号和模型服务的后续对话沿用已显示的问答，原始工具结果、附件和模型内部推理仅用于原轮次。
- 按作业名称可以检索已截止的 Canvas 作业。唯一匹配时会读取说明，题目在附件中可通过「课程文件」接着读取。

## 桌面与 MCP

Windows、macOS 或 Linux 客户端可复用 Dart 会话、模型适配器和校园工具注册表，为注册表注入桌面 Core 客户端及平台凭据存储。Android 通过应用内 Function Calling 执行校园工具，使用已有的 App 桥接。

Rust [Core Host](../../core/crates/dansheng-host/src/mcp.rs)已有 stdio MCP 适配器，并按专用客户端身份与授权调度 Core 的校园读方法。未来 Headless 入口可沿用相同的 Core 方法和权限检查，在 Host 侧提供客户端可见的工具清单，并按需要增加经过鉴权的 Streamable HTTP 传输。校园业务、认证和缓存继续由 Core 与平台服务负责。Android 已有的回环配对入口仍可在「本地检索与配对」中访问。
