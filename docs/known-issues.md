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
