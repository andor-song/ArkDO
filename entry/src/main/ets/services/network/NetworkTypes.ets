export enum ChallengeState {
  NONE = 'none',
  SUSPECTED = 'suspected',
  REQUIRED = 'required'
}

export enum NetworkErrorCode {
  NOT_IMPLEMENTED = 'not_implemented',
  CHALLENGE_REQUIRED = 'challenge_required',
  UNEXPECTED_RESPONSE = 'unexpected_response',
  NETWORK_FAILURE = 'network_failure'
}

// 失败原因的细分。为什么要有它：上面几种 code 都是 NETWORK_FAILURE / UNEXPECTED_RESPONSE，
// 但在**用户语言里的引导完全不同** —— 没选论坛要「先去添加论坛」、请求环境没就绪是「正在准备，
// 等几秒」、页面里 fetch 都发不出去是「检查网络」、脚本没回话是「重试」，而本仓自己拦下没发请求的
// 那些（参数不完整 / 档位非法 / 中途切了论坛）说「检查网络」纯属误导。
//
// 旧结构里这些共用一个 code + 一句内部文案，想区分只能去猜 message 含不含「宿主」「超时」。
// 字符串匹配是静默失效的源头：改一次措辞，判定当场失真而测试还是绿的。所以由**产出方**在造
// 失败对象时一次标好，界面层按值分类，永不读文案。
//
// 注意：标不上就留 undefined（按「未知失败」给一句通用引导），不要为了填值乱标一个 ——
// 乱标的代价是把用户往错的方向领（把真断网说成「正在准备请求环境」，用户会一直干等）。
export enum NetworkFailureKind {
  NO_ACTIVE_SITE = 'no_active_site',
  HOST_NOT_READY = 'host_not_ready',
  // 注入页面的 fetch 自己失败了（断网、连接被拒、DNS 污染都归这一档）。
  TRANSPORT = 'transport',
  // 等满 DEFAULT_TIMEOUT_MS 没回执：请求环境僵死的典型信号。
  TIMEOUT = 'timeout',
  // 脚本抛错 / 回执不是可解析的 JSON：环境在，但这次没给出能读的结果。
  SCRIPT_FAILURE = 'script_failure',
  // 写请求拿不到 CSRF（会话已过期）。**必须与 TRANSPORT 分开**：这条的正确引导是「重新登录」，
  // 说「检查网络」会让用户在网络设置里白折腾一圈，而重试永远不会成功。
  SESSION_EXPIRED = 'session_expired',
  // 本仓在发请求前自己拦下（本地校验、会话代次已变）。不是网络问题，别引导用户去查网络。
  LOCAL_ABORT = 'local_abort'
}

export interface NetworkError {
  code: NetworkErrorCode;
  message: string;
  requiresChallenge: boolean;
  // 见 NetworkFailureKind。仅当 code===NETWORK_FAILURE 且有意义时给出。
  failureKind?: NetworkFailureKind;
  // **可以直接展示给用户**的原因:服务端按站点语言本地化过的校验文案(Discourse 422 的 errors[]),
  // 或本仓自己写给用户看的校验提示(如「请至少选择一个类别」)。
  //
  // 刻意与 message 分开、而不是复用 message:message 是排查用的原文,里面允许出现「ArkWeb」「宿主」
  // 「JSON」这类内部名词,它只进日志与诊断快照;userReason 才是界面语言。
  // 缺省 undefined = 没有可信文案,由映射层按结构分类给一句用户语言。
  userReason?: string;
}

export interface NetworkResult<T> {
  success: boolean;
  statusCode: number;
  challengeState: ChallengeState;
  data?: T;
  error?: NetworkError;
  // 服务端明确判定「未登录」(Discourse 403 error_type=not_logged_in)时置 true。
  // 与 requiresChallenge 正交:CF 挑战是流量层拦截,这个是账号层鉴权失败。
  // 缺省 undefined = 未检出;false 亦可。仅当错误响应体里带明确的 not_logged_in 特征才置真,
  // 避免把「网络/解析失败」误判成未登录。给上层(通知页等)区分「重试」和「去登录」两种引导。
  notLoggedIn?: boolean;
  // 响应头带 `Discourse-Logged-Out: 1` 时置 true —— 这是**服务端正面证据**:本次请求携带的
  // 认证 cookie(`_t`)已被判定失效(BAD_TOKEN)。**404 本身说不出这句话**:同样的 404 既可能是
  // 「这个设备一直是游客」,也可能是「你的令牌被注销/轮换掉了」,而 /session/current.json 对两者
  // 都回 404 + 空体,光看状态码分不开。
  //
  // 为什么值得单独接住:上游在 `DefaultCurrentUserProvider` 里对 BAD_TOKEN 会
  // ① 打上 `_DISCOURSE_BAD_TOKEN` ② 由 `lib/hijack.rb` 回该响应头 ③ 顺带 Set-Cookie 删掉 `_t`。
  // 也就是说**令牌已在服务端作废、且本机 cookie 仓里的这一份也保不住了**。客户端据此再去做
  // 「拿备份令牌自愈」之类尝试只是徒增一组 404(还会消耗同 IP 的 cookie_auth 限流额度)。
  // 缺省 undefined = 未检出(含服务端未回该头的旧版本,调用方不得把 undefined 当 false 的反证)。
  loggedOutByServer?: boolean;
}

// 注入式 fetch 的附加请求头。名与值都会被 JSON.stringify 后嵌进脚本字面量,调用方给原始字符串即可。
export interface HttpHeaderEntry {
  name: string;
  value: string;
}

export interface JsonRequestOptions {
  notifyChallenge?: boolean;
  // POST 专用:把请求的 Referer 设成同源的某个页面(如帖子页),让请求更像浏览器真实发出的。
  referrer?: string;
}

export interface JsonNetworkClient {
  getJson(path: string, options?: JsonRequestOptions): Promise<NetworkResult<string>>;
  postForm(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>>;
  // POST + application/json body(发表评论/回复用),CSRF/cookie 与 postForm 同源自动处理。
  postJson(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>>;
  // PUT + 空 body(表情回应 toggle 用),CSRF/cookie 与 postForm 同源自动处理。
  putJson(path: string, options?: JsonRequestOptions): Promise<NetworkResult<string>>;
  // PUT + application/x-www-form-urlencoded body(投票 PUT /polls/vote 用),CSRF/cookie 同源自动处理。
  putForm(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>>;
  // DELETE + application/x-www-form-urlencoded body(撤销投票 DELETE /polls/vote 用),CSRF/cookie 同源自动处理。
  deleteForm(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>>;
  // 上传图片到 /uploads.json(multipart):base64 为压缩后图片字节的 base64,在 host webview 内还原成
  // Blob 拼 FormData 提交(原生 netstack 会被 CF 挡,只有 webview fetch 能过盾并带会话 Cookie)。
  // 返回 /uploads.json 的 JSON 响应文本(含 short_url 短码与真实 url),由上层解析。
  uploadImage(base64: string, fileName: string, mimeType: string, options?: JsonRequestOptions): Promise<NetworkResult<string>>;
}
