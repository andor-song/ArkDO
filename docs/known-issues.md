# 待解决问题记录

> 本文件记录已发现、待后续专门处理的问题。图标相关改动不在此列（已单独处理）。

## 问题 1：~~底层错误文案直接上屏~~（1.0.9 已修复，见下）

**修复方式**：新增 `services/network/UserFacingError.ets` 作为**唯一**的「失败 → 用户语言」映射处，
按**结构字段**分类（`challengeState` / `requiresChallenge` / `error.userReason` / `error.failureKind` /
`notLoggedIn` / `statusCode`），不按 message 字符串匹配。调用点改为
`friendlyFailure(result, { subject, action })`，原始 message 由 `rawFailure(result)` 留在日志里。

配套的结构化信息（缺了就只能猜字符串，迟早静默失真）：
- `NetworkError.failureKind`（`NetworkFailureKind`）：区分「没选论坛 / 请求环境没就绪 / 断网 / 超时 /
  脚本失败 / 会话过期 / 本仓自己拦下」。其中**会话过期**与**断网**必须分开 —— 前者要重新登录，
  说「检查网络」等于让用户白折腾。
- `NetworkError.userReason`：站点按用户语言写好的校验原因（Discourse 422 的 `errors[]`），
  或本仓写给用户看的本地校验提示。只有桥握着原始 body，所以由产出方标一次，界面原样透出。
- 桥的 executor 失败改为携带 `ExecutorFailure`（message + kind）：原先超时/脚本失败/解析失败
  被统一压成「ArkWeb 请求失败。」，分类信息在 catch 里就丢了。

顺带修掉的两处结构缺陷（都会让上面的映射失效）：
- `forwardFailure()` 原先只搬 4 个字段，**丢掉 `notLoggedIn` / `loggedOutByServer`** ——
  「未登录」这个信息在穿过任何一个 service 时就没了，「去登录」与「重试」分不开。
- 桥的非 2xx 分支把 body 留在 `data` 里，但只有 `TopicService.postFailure` 三个点会去读它；
  现在桥自己解析一次并标进 `userReason`，列表/书签/资料撞 422 时也能说出具体原因。

覆盖范围：14 个页面文件 + `CreateTopicFlow` + `SearchOverlay` + `NotificationPage`（原清单外），
外加 `WebViewPage` 的 `getErrorInfo()`（改为 `friendlyWebLoadFailure(errorCode)`，
`ERR_NAME_NOT_RESOLVED` 之类只进日志）。

**为什么当初不做乐观文案映射的顾虑不成立**：日志留了完整指纹（`rawFailure` 的
`code/status/kind/challenge/errMsg`），「设置 → 诊断日志 → 网络快照」照旧能拿到排查材料。

---

## 问题 2：HDS 原生标题栏菜单在窄屏上会被静默挤掉（1.0.15 改掉两处，其余待真机确认）

**现象**（真机 PLU-AL10，1316×2832，1.0.14）：帖子详情页顶栏挂 3 个原生菜单项，只画出 1 个；
另一帖挂 2 个，**一个都不画**。没有「还有 N 项被收起」的痕迹，点空白区域也无反应。
等于帖内搜索 / 只看某人 / 图片墙 / 编辑主题信息 / 手动验证这五个已开发完的功能在手机上没有入口。

**机制**：`HdsNavigation` 的 `menu` 与 `stackBuilder`（自定义标题内容）要的是**同一段标题栏右侧
空间**。自定义标题里的 `Row().width('100%')` / `layoutWeight(1)` 会把这段宽度吃光，超出的菜单项
直接不渲染。SDK 里 `menu.maxCount`（默认 3，`@hms.hds.hdsBaseComponent.d.ets:1637` 附近）说的是
「最多画几个图标」，**不是**「剩下的收进溢出菜单」——所以 `WebViewPage` 里「maxCount=2 时剩余两项
由 HDS 自动收进更多菜单」那句注释是错的，别照着它做设计。

**已改（1.0.15）**：两处「自绘标题栏 + 原生菜单」的组合，菜单全部换成自绘按钮/面板，固定宽度
与标题各拿各的：
- `TopicDetailPage` / `TopicDetailHeader`：常驻「⋯」按钮 + 自绘底部动作面板（提交 54e061f）。
- `ComposerPage`：标题栏右侧 40vp 自绘发送按钮（原来是给原生菜单预留的透明 `Blank`）。
  这条更要紧——发送是发帖/发私信**唯一**的提交入口，不渲染就是「写了半天发不出去」。

**未改、风险待真机判定**（这些页面用系统 `mainTitle`（不用 `stackBuilder`），理论上系统会给标题
加省略号而不是吞掉菜单，但本仓没有实测数据）。按「菜单是否唯一入口」+「标题是否动态」排序：

| 页面 | 菜单项 | 标题 | 丢了会怎样 |
|---|---|---|---|
| `WebViewPage.ets:164` | 3 项（`maxCount:2`） | **动态**：网页 `<title>` + host 副标题 | 刷新/复制链接/用浏览器打开全丢（那两个按钮只在加载失败遮罩里） |
| `UserProfilePage.ets:348` | 2 项 | **动态**：滚动后换成 displayName | 静音/忽略、在网页中打开都不可达 |
| `ProfilePage.ets:243` | 1 项「设置」 | 固定「我的」 | **全 App 唯一的设置入口**（网络/DoH/字号/诊断/登出都在里面） |
| `SitesPage.ets:307` | 1 项「添加站点」 | 固定 | 列表非空时唯一入口 |
| `MessageInboxPage.ets:87` | 1 项「新建私信」 | 固定 | 唯一入口（空列表没地方挂按钮，才放进标题栏的） |
| `DohSettingsPage.ets:257` | 1 项「添加 DoH」 | 固定 | 唯一入口 |
| `NotificationPage.ets:120` | 1 项「全部已读」（有未读才出现） | 固定 | 唯一入口 |
| `ForumsPage` / `ProfileEditPage` / `PrivateMessageComposePage` | 各 1 项 | 固定 | 页面内另有同款按钮，丢了自愈 |

**真机判法**（一次拍完，别猜）：进每个页面 `uitest dumpLayout`，看标题栏右侧有没有对应图标节点；
`WebViewPage` / `UserProfilePage` 要专门喂一个**长标题**（打开一个标题很长的网页 / 进一个 displayName
很长的用户主页）再拍一次——短标题过了不代表长标题也过。哪页丢了，就照 `TopicDetailHeader` 的自绘
按钮改法补一枚（固定宽度、`stateEffect`、透明底），并把那条 `menu:` 删掉，不留两套入口。

---

## 问题 3：ArkWeb 执行器整段卡死约 61 秒，期间所有请求都以 15s 超时失败（未修，已定位到窗口）

**证据**（真机日志 10-29 00:16:15 → 00:17:16，10 个文件里 13 条 `failed before response envelope`
有 10 条挤在这个窗口）：

```
00:16:15.195 GET /latest.json start
00:16:20.197 force host ready reason=waiterTimeout dropped=1     ← 全日志仅此一次
00:16:35.198 ArkWeb executor reject requestId=arkdo_655 reason=ArkWeb 请求超时。 kind=timeout
…（657 / 658 / 659 / 660 / 662 依次同样在 15.00s 处被拒；期间新请求照发不误）
00:17:16.489 reject arkdo_662 (POST /drafts.json)   ← 这一条引出了后续的草稿 409(1.0.15 已修)
```

重启后同一症状复现过一次（09:25:41 `/session/current` 超时、09:26:34 `GET /t/topic/2904899.json`
超时 → 详情页报 `kind=timeout`，用户手动重试 1.6s 就成功；**超时的主题加载没有自动重试**）。
17 分钟后（00:27:48 → 08:51:31）进程被系统杀掉，所以不是心跳丢失。

**判断**：`force host ready` 只是把等待者丢掉（`dropped=1`）并允许新请求出发，**没有重建 host 的
JS 上下文**；上下文已经死了的话，之后每个请求都只会走满 15s 超时。晚到的回包被
`ArkWeb callback ignored` 丢掉（全日志 19 条，其中 `arkdo_656` 同一 id 被忽略两次）。

**1.0.16 已加观测（不改行为）**：执行器每次超时打一行
`ArkWeb executor timeout requestId=… consecutiveTimeouts=N pending=… hostGeneration=…`；
任何回执或非超时失败都会把连续计数清零；`markHostLoadIssued` 每次 `loadUrl` 自增代次并打
`host load issued generation=…`。明天复现时看两点：连续计数是否一路涨到 ≥3（说明上下文已死，
不是偶发慢），以及卡死窗口的 `hostGeneration` 是否与某次重载重合。

**仍未做**：详情页/列表页对「超时」的自动重试（现在只有 CF 403 那条重试链有 6 次 2s 退避）；
以及「重建 host 文档」与「换执行通道」之间的取舍——等上面的观测数据。

## 问题 4：`csrf source=none` 让 13 次写请求直接本地中止（1.0.16 已修，待真机复验）

`csrf source=session length=86` × 89 与 `csrf source=none length=0` × 13：13 条全部落在
10-29 00:03:27 → 00:17:26，其中 12 条 `POST /topics/timings` + 1 条 `POST /presence/update`。
矛盾样本：00:14:08.571 timings 报 `source=none`，2.5 秒后 `POST /clicks/track` 却是 `source=session`
并 200；同一分钟里草稿保存也一直是 `source=session`。代价是已读进度真的丢了：
`[ArkDO][ReadingTracker] report failed` × 14、`drain report … success=false status=0` × 2，
主题 3046615 / 3024844 的已读位置永久缺了那几批。重启（08:51）之后 `source=none` 归零。

**根因**：注入脚本的 `readCsrf()` 把三类完全不同的失败都 `catch` 成空串——fetch 传输失败、
`r.json()` 解析失败（CF 挑战页是 HTML）、响应里没有 `csrf` 字段。随后一次**零延迟**重读撞在
同一个抖动上，再落到「没有 meta 令牌」分支，就断言 `session may be expired` 并中止写入。
证据本身否定了这个结论：同一分钟草稿保存是 `source=session`，2.5 秒后的 `/clicks/track` 也成功。

**已改（1.0.16）**：
- 读取失败逐项留证（`http_<status>` / `malformed` / `missing` / `transport:`），回执带上
  `csrfAttempts / csrfLastStatus / csrfLastError / csrfCfMitigated / csrfLoggedOut`。
- 重试改为 `[0, 300, 900]ms` 退避（`CsrfFailurePolicy.CSRF_RETRY_DELAYS_MS`），最坏新增延迟 1.2s。
- 读不到时先复用最近一次成功令牌（`window.__arkdoCsrfCache`，TTL 2 分钟，按 origin 隔离），
  再落 meta；只有**明确登出证据**才作废缓存。
- 分类上移：脚本只报 `csrf_unavailable`，由 `classifyCsrfFailure()` 按正面证据（`discourse-logged-out`、
  401、非 CF 的 403）升为 `SESSION_EXPIRED`；其余按网络档提示「稍后重试」，不再把用户赶去重新登录。
- 顺带修掉 fail-fast 后主链继续执行、对同一 requestId 再回一个 `TypeError` 失败回执的问题。

**真机复验**（明天）：日志里 `source=none` 应显著变少；若出现，同一行会带 `attempts/lastStatus/lastError/cache`，
界面提示应是「网络不顺畅」而不是「请重新登录」。已读上报仍按 status=0 退避 4 档（5/10/20/40s），
若这 4 档全部落在执行器卡死窗口内仍会丢批——那是问题 3，不是 CSRF。

## 问题 5：重复请求（1.0.16 修掉一条，其余待真机确认触发点）

- ~~`GET /session/current.json` 在**同一毫秒**被发两次~~（1.0.16 已修：`AuthService.probeSession()`
  把并发调用合并成同一个在途 Promise，落地即释放；`AuthService.test` 有对应用例）。
  原始证据：10:07:22.316，`arkdo_123` / `arkdo_124`，
  触发点是 `foreground session recheck`；另外两次前台恢复也是 0.5–1.8s 内成对。
- 同一条搜索被发两次：09:21:37.404 与 09:21:37.774 都是 `GET /search.json?q=codex 计划怎么不显示了`，
  **两次都 200 且都 59910 字节**（一次查询 120KB），两次结果都渲染了。
- 同一批 21 个 `post_ids` 的 `GET /t/{id}/posts.json` 13 秒内取 4 次（gaps 0.84/1.63/1.89/0.80s）。

对照：`GET /latest.json` 的 403 重试是固定 2.000s × 最多 6 次、成功即停 —— 那条是**有意**的。

## 问题 6：CF 诊断说「已解决」但 `hasCfClearance` 全程 false（1.0.16 已把字段改名，只影响诊断可信度）

00:14:20→00:14:33 那次挑战：13 条 `[ARKDO_CF_DIAG]` 采样**每一条**都是 `hasCfClearance=false`，
包括最后 `stage=resolvedBySource404 … hasResolved=true`；可之后 00:15:04 的草稿保存确实 200 了。
结论：解决判定（404 即认为过盾）是对的，**clearance 探测看错了 cookie 仓**（sheet 期间
`cookieHeaderLength` 反而从 1697 降到 1636）。同一时段 `[Challenge] required` 的 version 自增 37 次，
而 `rootChallengeOpen` 只触发 1 次（25 次是 30s 冷却里的 `recoverySwallow state=3`）。

**1.0.16 已改（只修可信度，不改判定）**：`cf_clearance` 是 HttpOnly，`fetchCookieSync` 不保证
把它列出来——所以那个 false 本来就不能读成「没有通行证」。日志字段已从 `hasCfClearance` 改名为
`cfClearanceCookieVisible`，`WebSessionManager.hasCfClearance()` 改名 `isCfClearanceVisible()` 并写明
「false 只代表看不见」。过盾真值仍以 `resolvedBySource404` / `hasResolved` 为准。

---

## 已修复（留此一行，避免被重新发现一遍）

- ~~首页加载帖子列表时出现两个 loading~~：`refreshLatestTopics()` 里 `isInitialLoading` 与 `isRefreshing`
  早已互斥赋值（列表为空时只走中间主 loading，`isRefreshing` 恒 false），同款写法覆盖全部 10 个分页列表页。
- ~~加载失败文案不友好且缺少明显的重试入口~~：空态文案已是「内容加载遇到访问验证，请稍后重试」/
  「加载失败，请检查网络后重试」，并挂上 `LoadStateView` 的「重试」按钮；内部词也已从界面清掉。
  动态透传那一路（问题 1）也已在 1.0.9 一并收口到 `UserFacingError`。

---

## 沉浸光感不适配范围

沉浸光感首批只用于导航、固定操作、输入浮层和登录面板。

以下区域不使用沉浸光感：

- 帖子列表项正文和标题行。
- 未读小蓝点和未读数字药丸。
- 帖子详情富文本正文、投票、代码块、onebox、图片、音频、视频。
- Cloudflare challenge 页面。

原因：这些区域以阅读和验证稳定性为主，光感材质会增加视觉噪音或引入验证页风险。
