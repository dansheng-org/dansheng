# 图书馆与 eHall 认证协议核验

日期：2026-11-09。前半部记录独立worker的匿名审计，当时仅新增本文，没有读凭据或登录。文末另列主线程后续受授权的eHall固定目标认证和私有self队列实读；生产Rust输入仍冻结、未提交代码。公开/私人响应仅在保护进程或私有Core profile中处理，不保存原始包、Cookie、SSO state/ticket、OAuth code/token或签名URL到文档。本文仅记录origin/path、参数键、脱敏结构和计数，没有续借、预约、取消或业务提交。

证据等级：**P** 为本次匿名 GET 实测；**S** 为官网直接引用的公开代码；**H** 为接入建议。S 不证明认证端点当前可用，也不证明私人响应 schema。上一份学生服务研究见 [library-student-services.md](library-student-services.md)，门户研究见 [portal-life-services.md](portal-life-services.md)。

## 当前判断

| 服务/阶段 | 当前证据 | 接入判断 |
| --- | --- | --- |
| OPAC 公共书目/馆藏 | P：精确 singleVolume 查询、由结果发现的 smjlh 书目与 v2 holdings 返回 200 JSON | 原生 Anonymous HTTP 已有正面数据证据；不依赖已登录页面。本文不保存此次查询值或发现的具体书目 ID。 |
| OPAC 获取私人凭据 | S/P：当前登录是第三方 OAuth SPA，配置分支会发认证 POST；旧主页登录页 404，旧 callback 返回错误 JSON | 首个接入采用平台可视登录与受控凭据交接。原生 OAuth 登录存在可研究的明确协议，但尚未实现/验证；不能把现有 UIS Cookie 登录适配器直接当作完成。 |
| OPAC 私人读 API | S：固定 fdulspgw API 使用 `access_token` 秘密头；Core 已有 HostHeaders/SecretHeaders 接线 | 凭据建立后可用原生 SecretHeaders 读取；本轮没有有效 token，私人 schema 仍为 unverified。登录使用浏览器不意味着所有借阅 GET 必须 BrowserSession。 |
| eHall 公共目录 | P：匿名目录 JSON；总量元数据不可靠 | 原生 Anonymous HTTP 可读有界目录；目录可见性不是账号权限。 |
| eHall 获取私人会话 | P：无凭据身份 GET 到登录入口；无 Cookie 的普通跳转链落入错误页。S：页面身份 API 使用同源凭据 | 原生登录尚未得到正面完成证据。先由平台可视认证交接服务会话；后续固定 native login 目标需独立验收，不能宣称仅加目标 origin 就已可用。 |
| eHall 私人读 API | S：同源 GET + `withCredentials`；P：AJAX 无凭据请求返回登录错误封套 | HostSession 是目前连接器明确选择的读模式。若实际出现 WAF/页面执行要求，改由显式平台 BrowserSession；不得在两者间静默 fallback。 |

这里的“采用平台可视登录”是现阶段接入选择，不是断言服务永远不支持原生认证。SPA、`withCredentials` 或一次匿名错误本身都不能证明所有 API 必须在浏览器执行。

## OPAC：旧入口与当前入口必须分开

来源：[图书馆官网首页](https://library.fudan.edu.cn/)、[OPAC 首页](https://opac.fudan.edu.cn/)。官网同时保留旧 Aleph/旧 callback 与新 Vue 门户链接。

| 本轮匿名 GET | 实际结果 P | 可得结论 |
| --- | --- | --- |
| `https://opac.fudan.edu.cn/fdu_login.html` | HTTP 404，nginx HTML | 该旧入口本次不可用；不推导为图书馆所有认证失效。 |
| `https://opac.fudan.edu.cn/api/oauth/callback`，参数键 `login`；按官网声明的静态模式请求，无 OAuth code/ticket | HTTP 200 JSON；顶层 `success,code,msg`，`code=500`，无 data | 旧 callback 在无认证上下文时返回错误。没有取得凭据，不能用 HTTP 200 证明登录成功。 |
| `https://opac.fudan.edu.cn/` | HTTP 200，Vue SPA 壳；直接引用 manifest/vendor/app | 当前前端入口成立，业务与认证仍需执行其协议。 |
| 从当前 app 原样发现的 `https://fdulib.a-lsp.com/authServer/` 登录链接，参数键 `target,response_type,loginType,client_id,redirect_uri` | HTTP 200，509 字节左右 HTML SPA 壳，引用 `assets/index-MZ93USXv.js` | 当前认证进入第三方 authServer SPA。没有提交认证信息，参数值及跳转上下文不保存。 |

当前 app 来源：[app.ea0f02cf08d19b244213.js](https://opac.fudan.edu.cn/static/js/app.ea0f02cf08d19b244213.js)。文件名可能更新，生产从官网重新发现，不将其当永久配置。

## OPAC：当前 OAuth 到 access_token 的确切静态链

当前 app 的 `goLogin` 清除旧 `token` 存储，并把原路由保存到 `sessionStorage.redirectPath`，进入 `/#/loginRedirect`。该组件构造第三方 authServer 登录链接，注册返回地址指向 OPAC `/#/redirect`。该返回组件从 location 中读取参数键 `code`，没有 code 时不会交换凭据。

### OPAC 返回组件 S

| 步骤 | origin/path | 方法、参数键与响应访问 |
| --- | --- | --- |
| 取得登录授权上下文 | `https://fdulib.a-lsp.com/authServer/` | 浏览器导航；键 `target,response_type,loginType,client_id,redirect_uri`。实际租户/认证方式由第三方配置决定。 |
| 交换返回 code | `https://fdulspgw.fudan.edu.cn/alsp/open-api/openapi/oauth2/getToken` | **GET**；键 `client_id,code,grant_type`。代码为 authorization-code 风格；仅 `data.code=200` 后读取 `data.data.access_token`。本轮未调用此端点。 |
| 核对 token 对应读者 | `https://fdulspgw.fudan.edu.cn/alsp/open-api/elib5/getReaderInfo` | **GET**；秘密头键 `access_token`，前端读取 `data.data` 并访问 `barcode,name,email`。私人响应尚未实测。 |
| 获取认证来源 | `https://fdulspgw.fudan.edu.cn/alsp/open-api/elib5/getReaderAuthSource` | **GET**；同一秘密头，前端将成功 data 保存为 authSource。此数据不是 UIS 账号身份的独立证明。 |

不把交换凭据的 GET 当普通只读业务 GET：它消费认证上下文，不在公开资料/目录探针中调用，不能携带真实 code 自动重试或导出其 URL。没有观察到成功 code/callback 及 token 交换，因而此链只到 S，不是完成的 native login 证据。

### 前端保存方式 S

app 的 `g.get/set/del` 包装 `document.cookie`：token 交换返回的 access_token 写进 **OPAC origin 下名为 token 的可读 Cookie**，`path=/`；前端本地代码设置约两小时期限，并有约半小时闲置后清理/切换登录的逻辑。两者是客户端行为，不是服务端 token 的有效期保证，Core 不据此硬编码凭据寿命。

随后私人读请求从这个指定 token 存储位置取值，作为 **fdulspgw 请求的 `access_token` header**。这证明“一个特定应用存储项是其前端取得的 token”，不证明“任意 Cookie、UIS Cookie 或所有 OPAC Cookie 都是 access_token”。不能将 Cookie header 直接复制为该秘密头，不能把 OPAC Cookie jar 默认发送到 fdulspgw，更不能把第三方 authServer 的本地 token 混为图书馆读 token。

## 第三方 authServer：为什么目前不是现成 native login

来源为该认证页直接引用的 [index-MZ93USXv.js](https://fdulib.a-lsp.com/authServer/assets/index-MZ93USXv.js)，及它导入的 [index-DeYXGjE8.js](https://fdulib.a-lsp.com/authServer/assets/index-DeYXGjE8.js)。两者本轮匿名 GET 可读；只调查脚本，没有调用下表认证 API。

### 页面启动与配置分支 S

路由守卫先按 `website=location.host` 获取租户；随后使用 `loginType`、可选 `libCode` 查询登录配置。配置存在 `enable`、`thirdPartyAuthEnable`、`buttonLink` 分支，符合分支条件时调用 `getClientParams(route.query)` 并以返回 data 进行 `window.location.replace`。不能只凭最初链接推定后面必定是 UIS 密码页。

这个包内 Axios 的构建配置 `VITE_BASE_URL` 为空，API 路径以 `/` 开头，故下列路径在 **fdulib.a-lsp.com origin 根目录**，不是把 `/authServer/` 任意加到 API 前面。运行时封装还可能附加 header 键 `tenant-id`、`openToken` 和 `Accept-Language`；这些上下文/值本轮没有取得或保存。

| 名称 | 静态方法/path | 已见参数/输入形状及限制 |
| --- | --- | --- |
| getByWebsite | GET `/admin-api/system/tenant/get-by-website` | params 键 `website`；回包租户 ID 放入应用 store。仅静态发现。 |
| getConfig | GET `/open-api/openapi/oauth2/config` | params 键 `loginType,libCode`；返回配置决定认证分支。仅静态发现。 |
| getClientParams | **POST** `/open-api/openapi/oauth2/getClientParams` | data 为当前路由 query；可返回继续认证的 URL。未请求；不会为了测试“只是获取跳转”而发认证 POST。 |
| getCaptcha | GET `/open-api/openapi/oauth2/getCaptcha` | 验证码入口；没有请求验证码或解码/绕过验证。 |
| getLoginPublicKey | GET `/open-api/anonymous/system/pub-key` | 独立第三方公钥协议，不等于现有 Fudan ID 公钥协议。未请求。 |
| doLogin | **POST** `/open-api/openapi/oauth2/doLogin` | URL params 允许键 `loginType,client_id,redirect_uri`；JSON body 是 name/pwd、公钥加密/时间/nonce 等字段的固定筛选。未提交，也不移植密码或加密材料。 |
| authorize | GET `/open-api/openapi/oauth2/authorize` | params 转交协议上下文；未知是否创建/确认授权，未请求。 |
| checkLogin | GET `/open-api/openapi/oauth2/checkLogin` | 无显式 params 的状态检查；没有有效认证上下文，未请求。 |
| doConfirm / authCallBack / getSilentAuth | GET `/open-api/openapi/oauth2/doConfirm`、`/authCallBack`、`/getSilentAuth`（同 oauth2 前缀） | 有认证侧效应或上下文依赖，全部停留静态审计。 |

logout、密码更新也存在于共享包，但不属于此次读取或未来首批私人查询。只有相关静态列表，没有访问这些动作。

现有 [login.rs](../../crates/dansheng-connectors/src/login.rs) 是固定 Fudan 服务与 ID/UIS 流程，返回 **未验证的服务 Cookie session candidate**。本次读取的 LoginTarget 没有 Library/eHall；它没有第三方 OAuth 租户配置、返回 code 处理或 access_token 交接。因此“现有 native login 能生成 Cookie”不能证明图书馆 SecretHeaders 登录已完成。

## eHall：普通导航与 AJAX 的认证边界不同

来源：[eHall 首页](https://ehall.fudan.edu.cn/)，直接引用的 [index-XrYuYnyJ.js](https://ehallassets.fudan.edu.cn/vpage/project1/page1/assets/index-XrYuYnyJ.js)。

### 页面与原生身份读取 P/S

页面公共代码确切调用：**GET** `/personal/frontend/data/info`，成功解析 `.d.info`，保存为 `window.userInfoDSL`。Axios 设置 `withCredentials=true`，基址按当前页面 origin/路径确定；实际主封装的 `X-Requested-With` 值是 `XMLRequest`。它没有把 OPAC access_token 作为 eHall 认证头。

| 本轮匿名 GET | 实际结果 P | 含义 |
| --- | --- | --- |
| eHall `/` | 200 公共页面，返回 Set-Cookie header（未读取/输出其值） | 仅取得匿名页面/匿名会话元数据，不是认证。 |
| `/personal/frontend/data/info`，无 AJAX header、无 Cookie | 302 → `/manage/common/login/index`，键 `redirect` | 原生直接 GET 看到了明确登录边界。 |
| 从上述 Location 继续无 Cookie 的有限 GET | 登录入口 302 → `/manageorg/error`，键 `msg,code`；最终 200 HTML 错误页 | 匿名、无 Cookie 的这条链没有完成 SSO。未输出 msg/redirect 上下文值，也不能由此推断校园业务停机或所有账号无法登录。 |
| `/personal/frontend/data/info`，`X-Requested-With: XMLRequest`，无 Cookie | 200 JSON；顶层 e/m/d；`e=10013`，m 含登录提示，d 只有 `loginUrl`，其 origin/path 为 eHall `/manage/common/login/index`，键 `redirect` | AJAX 返回登录错误封套，不是合法空 `.d.info`。没有取得个人字段。 |
| 同一 GET，标准 `XMLHttpRequest` 值，无 Cookie | 相同的 200/e=10013 登录错误封套 | 两个值本次都触发 AJAX 错误响应；不能因此声称认证后每个接口都无差异。 |

错误回包 d.loginUrl 是认证跳转指令，不能纳入普通任务 JSON、缓存、MCP 或日志。`e=10013` 是本次**匿名身份请求**的具体失败，不把它自动推广为所有任务端点、所有版本或任意业务的错误码契约。它也不是 HTTP 200 身份成功；不得把 `.d.info` 缺失当“用户没有个人数据”。

私人 `.d.info` 的身份键、角色范围和同一人的比对方式，本次没有真实响应，仍标 **unverified**。不能把它等同于 my 数据中心资料，也不能通过姓名、格式相似的账号或图书馆 reader barcode 自动完成跨服务绑定。

## 凭据交接与下一步验收 H

### OPAC

1. 平台在用户可见的官网登录页面完成当前 authServer 流程；第三方/UIS 每个 origin 固定批准，未知配置跳转不跟随。保留官方注册返回地址，不能未经客户端注册验证擅改为 localhost 或任意 deep link。
2. 返回上下文只由可信平台处理，不进入聊天、MCP、诊断、source JSON 或普通插件 KV。当前公开 OPAC 分支未展示足以审计整个提供方的 state/PKCE 约束；不能据此断言提供方没有这些机制。平台必须独立绑定发起人、当前账号、发起时间及一次性流程，不能接受任意页面送来的 code/token。
3. 优先让官方页面完成其 token 交换，再通过明确的认证 port 交接**该服务指定的 token**。如果未来实现 native 交换，需验证真实客户端注册、成功 callback、租户配置与参数编码；本轮没有完成这些工作。不要让 LibraryClient 本身承担密码/验证码或动态任意 URL 的认证代理。
4. token 仅写到宿主安全凭据存储，绑定 fdulspgw origin + account；学校秘密头键由官方 library connector 声明，平台/BoundTransport 注入值。获取了 Cookie、授权 code 或凭据已保存都不等于 getReaderInfo 验证通过。
5. 使用固定 SecretHeaders getReaderInfo 只读观察 token subject，并由可信 owner 核对实际本人后显式 bind。沿用 root 已接线的 observe/bind/clear Owner-only，不自动绑定，不接收 MCP 的 expected-reader 参数。只有可信绑定匹配才读 current/history；两类来源权限独立。观察/绑定不能借机续借或查询预约 POST。

### eHall

1. 在平台可视页面先完成实际登录，验证 eHall 自身身份响应，而非只验证 ID/UIS 或某个其他服务。
2. 若平台交接的是明确可用于原生 HTTP 的 eHall Cookie session candidate，先用固定身份 GET + 当前授权复核再读任务。Cookie 存储可按现有 HostSession 机制隔离；不能复制到图书馆 access_token header。
3. 若服务实际要求页面 WAF/JS 上下文，必须使用平台 BrowserSession 的 authenticated-page fetch/XHR。`withCredentials` 本身尚不足以判定这种要求；没有浏览器能力时明确报错，不用 Rust HTTP 偷换。
4. native login 扩展只能是新的固定官方目标与经过确认的跳转图；本次无 Cookie 匿名链在登录入口失败，不能据此登记“native login 已完成”。还需要授权后的成功 service session、本人身份及任务结构验收。
5. AJAX e=10013 登录错误需要按已观察到的认证失败处理/报告，不能升级为成功空数据。主线程如调整错误分类，需单独针对安全摘要与 token/session 类型验收；本文没有修改冻结源码。

## 原匿名审计结束时的边界

- 没有 Library/eHall 真实账号登录、成功 OAuth callback/token 交换、私人 getReaderInfo/.d.info、本人身份绑定或个人业务记录证据。
- authServer API 表全部是静态发现；未取得租户配置、验证码、公钥、openToken、AUTH_TOKEN 或授权状态。
- 没有认证 POST、旧/新密码登录、退出、确认授权、续借、预约/取消、searchReaderRequest 或其他业务写入。
- 只新增本文；已有 Library 24 项、Core bridge 与平台验收由主线程独立负责。本文不将这些离线/桥接结果合并成真实认证成功。

首批认证建议为“平台可视登录 → 服务专属凭据安全交接 → 固定原生身份验证 → owner 显式绑定 → 有界只读”。OPAC 私人头与 eHall Cookie session 分开；缺少哪个服务的正面证据，就保留哪个服务的 unverified 状态。

## 后续匿名复核：当前配置与另一条 eHall 登录图

同日独立复核仍未读取凭据、Cookie或真实profile，未认证POST。以下是新的公开实测，原无Cookie导航到错误页的样本继续保留，但不再作为唯一可能的登录图。

| 当前匿名 GET | 结果 | 接入影响 |
| --- | --- | --- |
| authServer `/admin-api/system/tenant/get-by-website`，键 `website` | HTTP200，`code=200`，`data`有 `id/name` | 当前租户发现协议成立；租户值不写入本文 |
| authServer `/open-api/openapi/oauth2/config`，键 `loginType`，由 OPAC 当前官方 app 链接原样取得 | HTTP200/code200，`enable=true`、`thirdPartyAuthEnable=true`、buttonLink非空 | 公开继续认证目标的 origin/path 为 `https://rwsjcas.fudan.edu.cn/gotoFdUisLogin`；最终UIS/ID分支和OAuth上下文仍未验证 |
| eHall `/manage/common/login/index` | 302到同源 `/fudan_rh/frontend/cas/index`，参数键 `redirect/channel` | 固定候选登录入口可以由原生导航得到，不必重建服务器query |
| eHall服务器返回的完整下一跳 | 302到 `https://id.fudan.edu.cn/idp/authCenter/authenticate`，参数键 `service` | 嵌套service的origin/path仍为 eHall `/fudan_rh/frontend/cas/index`；可研究复用既有ID协议，必须保留原始query和精确目的地限制 |

第三方 authServer 请求封装实际为 `withCredentials=false`，`tenant-id/openToken`条件注入；本次没有openToken或Cookie，带/不带公开tenant-id的config读取都成功。自动跳转的条件是`enable=false`并且第三方认证开启；当前`enable=true`不会触发。页面“其他登录”按钮要先用当前route.query调用 **POST `/open-api/openapi/oauth2/getClientParams`** 再导航返回URL。因此直接GET buttonLink能否保留当前OAuth客户端上下文尚未证明，也不能把UIS密码填入第三方的本地读者密码表单。

上述 eHall 图只证明登录候选入口到ID。主线程另用仓库外的固定目标原生认证原型做一次受授权的凭据验证；原型复用当前login协议的限次、期限、TLS和目的地验证，不修改冻结生产源、不加入发布包，也不作为新的生产login RPC。只有随后 eHall 自身 `.d.info` 成功核对本人，才继续调用当前Core的三个只读队列；结果以独立脱敏报告为准。

### 主线程后续私有实读

固定目标原型25项离线测试及strictClippy通过。新密码流程实际完成，`fresh_password_submitted=true`；只交接eHall目标Cookie，随后当前Core的固定私有info GET200/e0，包含非空uid/name。没有把不透明uid或姓名推断成学号，`identity_matches=null`；队列身份来自新凭据认证流程与服务私有self端点，两者共同核验后，仅请求不接受任意uid的当前账号队列。

当前Core的todo首页正常空结果、done首页1条，coverage均page；application为SourceSchemaChanged，私人申请协议仍待进一步核验。没有导出uid/name/任务正文或原始Cookie，没有生产login RPC、授权变更或远端业务提交。记录见[脱敏eHall读取](evidence/ehall-self-read.json)及其receipt；原型代码留在仓库外研究目录，未加入发布Core。
