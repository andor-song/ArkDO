# 待解决问题记录

> 本文件记录已发现、待后续专门处理的问题。图标相关改动不在此列（已单独处理）。

## 问题 1：底层错误文案直接上屏（面广，需一处集中清洗）

**现象**
很多页面把 `result.error.message` 原样显示给用户，而这条链的源头是网络层/服务层的内部文案，
例如「ArkWeb 请求失败。」「ArkWeb 宿主尚未就绪。」「站点帖子列表响应不是有效 JSON。」。
用户看到的是一个自己无法处理、也不该知道存在的技术名词。

**根因**
`services/network/ArkWebNetworkBridge.ets` 造的失败文案（含 `'ArkWeb 请求失败。'` 等）会经
`NetworkResults.forwardFailure()` **原样上抛**（该函数注释里就明写"不做二次解释"），再由各页面的
`this.message = result.error?.message` / `showToast(result.error.message)` 落到界面。
全仓**没有**集中的"失败 → 用户可读文案"映射层，清洗一直是各页自己写各自的。

**范围**（1.0.8 复核时逐调用点数。口径：`NetworkResult.error.message` 经赋值或中间变量进入
`LoadStateView` / `ListFooter` / toast 等可见文案才算；只进日志、只读 `requiresChallenge` 的不算。
全仓共 **14 个页面文件、29 处**。）
- 列表页空态（9 个文件、各 1 处）：`ReadTopicsPage` / `DraftsPage` / `MessageInboxPage` /
  `SolvedPostsPage` / `UserHistoryListPage` / `BookmarksPage` / `FollowersListPage` /
  `BadgesPage` / `ActivityListPage`，写法是 `this.message = result.error?.message ? ... : 兜底`。
- 字段名不同、但同样透传空态的两处：`ChatPage` 用 `stateMessage`，`LdcCreditPage` 用 `errorMessage`。
  它们不是列表页空态，也不符合 `this.message` 的写法，别按同一模式去搜。
- `TopicDetailPage` 共 14 处：页面空态 `message`、尾行 `loadMoreMessage`、回应列表错误各 1 处，
  另 11 处经 `showComposerToast` / `promptToast` 直出。
- 其余 toast 群：`UserProfilePage` 4 处、`BookmarksPage` 另 3 处、`DraftsPage` 另 2 处、
  `ProfileEditPage` 2 处；`ProfilePage` 有 1 处。
- 还有两处不属于 `NetworkResult`，但同属"底层文案上屏"：`ProfileEditPage` 的上传结果
  `outcome.error`，以及 `WebViewPage` 把 `WebResourceError.getErrorInfo()` 原样显示。
- 「正在准备 ArkWeb 请求环境」「宿主未就绪」这两类**固定**内部词已在 1.0.8 清掉，本条只管**透传**这一路。

**期望**
一个纯函数映射（如 `services/network/UserFacingError.ets`）：输入 `NetworkError` + 场景，输出
「网络不太顺畅，请检查网络后重试」这类用户语言；内部词一律不进界面，原始信息只进日志与诊断快照。
调用点替换成 `friendlyMessage(result)`。这样清洗只需写一次，也不会再加一个"漏改的页面"。

> 为什么当初不做乐观文案映射的顾虑不成立：日志已经留了完整指纹（`errMsg=` / 状态码 / 是否 CF 拦截），
> 「设置 → 诊断日志 → 网络快照」也在，排查材料不会因为界面变干净而丢失。

---

## 已修复（留此一行，避免被重新发现一遍）

- ~~首页加载帖子列表时出现两个 loading~~：`refreshLatestTopics()` 里 `isInitialLoading` 与 `isRefreshing`
  早已互斥赋值（列表为空时只走中间主 loading，`isRefreshing` 恒 false），同款写法覆盖全部 10 个分页列表页。
- ~~加载失败文案不友好且缺少明显的重试入口~~：空态文案已是「内容加载遇到访问验证，请稍后重试」/
  「加载失败，请检查网络后重试」，并挂上 `LoadStateView` 的「重试」按钮；内部词也已从界面清掉。
  **剩下的只有上面那条透传问题**（固定文案修完了，动态透传没修）。

---

## 沉浸光感不适配范围

沉浸光感首批只用于导航、固定操作、输入浮层和登录面板。

以下区域不使用沉浸光感：

- 帖子列表项正文和标题行。
- 未读小蓝点和未读数字药丸。
- 帖子详情富文本正文、投票、代码块、onebox、图片、音频、视频。
- Cloudflare challenge 页面。

原因：这些区域以阅读和验证稳定性为主，光感材质会增加视觉噪音或引入验证页风险。
