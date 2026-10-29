import { ChallengeState, NetworkError, NetworkFailureKind, NetworkResult } from './NetworkTypes';

/**
 * 「失败 → 用户可读文案」的唯一映射处。
 *
 * 为什么要有它：桥层与 service 层的失败文案是写给开发者看的，里面是架构名词
 * （「ArkWeb 宿主尚未就绪。」「站点帖子列表响应不是有效 JSON。」「站点返回 HTTP 422。」）。
 * 用户既看不懂也做不了任何事，而原先每个页面都写着 `this.message = result.error?.message ? … : 兜底`
 * ——等于把内部文案当界面文案用，清洗只能一页一页追（docs/known-issues.md 问题 1）。
 * 从这里开始：页面只负责说「我在做什么」，「该对用户说什么」由本文件一处决定。
 *
 * 四条硬约束：
 *  1) **按结构分类，绝不按 message 字符串匹配**。判据只有 challengeState / requiresChallenge /
 *     error.userReason / error.failureKind / notLoggedIn / statusCode。靠「含不含 ArkWeb」去猜，
 * 会在下次改文案时静默失效——本仓刚踩过「红而不跑等于没有测试」，别再踩「判而不中等于没有判」。
 *  2) **过盾优先**。CF 挑战是流量层拦截，必须先于任何业务原因展示（上层还要靠 error.code
 *     拉过盾流程，文案不能把这件事盖掉）。
 *  3) **服务端已经说过的话优先于我们的模板**。Discourse 的 422/409 文案是站点按用户语言写好的
 *     （「附件数量超过限制」之类），比我们能编的任何一句都有用；产出方把它标进
 *     error.userReason，本函数原样透出。
 *  4) **界面变干净不能把证据一起擦掉**。原始 message 只进日志，调用点用 rawFailure() 留一行，
 *     「设置 → 诊断日志 → 网络快照」的材料因此不受影响。
 *
 * 纯函数：不 import 任何 @kit/@ohos，可在本地 harness 直跑。
 */

// 失败分类。内部判定与单测断言用，页面不读它、只读 friendlyFailure 的文案。
export enum FailureCause {
  CHALLENGE = 'challenge',
  USER_REASON = 'user_reason',
  NO_ACTIVE_SITE = 'no_active_site',
  HOST_NOT_READY = 'host_not_ready',
  NETWORK = 'network',
  NEED_LOGIN = 'need_login',
  NOT_FOUND = 'not_found',
  CONFLICT = 'conflict',
  RATE_LIMIT = 'rate_limit',
  REJECTED = 'rejected',
  FORBIDDEN = 'forbidden',
  UPSTREAM = 'upstream',
  MALFORMED = 'malformed',
  // 本仓在发请求前自己拦下（本地校验、会话代次已变）。不是网络问题，
  // 说「请检查网络」会把人往反方向领，所以与 NETWORK 分开。
  LOCAL_ABORT = 'local_abort',
  UNKNOWN = 'unknown'
}

// 调用点提供的「用户正在做什么」。刻意用两个短词而不是几十个场景枚举：
// 文案由「主体 + 动作」拼出来，新增页面不必改本文件，也不可能「漏进接受集」
// （那样又会退化成标题字重那种点了没反应——参见 1.0.8 的 normalizeTitleFontWeight 事故）。
// 措辞给名词本身与动词本身，不要带标点，句子由本文件统一成形。
export interface FailureCopy {
  // 用户眼中的对象：'内容' / '帖子详情' / '这条回复' / '书签' / '通知'。
  subject: string;
  // 动作：'加载' / '发送' / '保存' / '删除' / '设置'。
  action: string;
}

function challengeRequested<T>(response: NetworkResult<T>, error: NetworkError | undefined): boolean {
  if (response.challengeState !== ChallengeState.NONE) {
    return true;
  }
  return error !== undefined && error.requiresChallenge;
}

// 产出方标注过的「可直接给用户看的原因」。为什么不在这里翻响应体：只有桥握着原始 body，
// 而失败对象穿过 service 时 data 早就不带了 —— 让界面层再 parse 一次既拿不到，也是把
// 「谁的职责」搞混。所以由产出方在造 error 时一次标进 error.userReason（见 NetworkTypes），
// 本函数只认那一个字段。两处都标不上才回落到按状态码编模板。
function userReasonOf<T>(response: NetworkResult<T>): string {
  const marked: string | undefined = response.error?.userReason;
  return marked !== undefined ? marked : '';
}

/**
 * 分类。顺序即优先级；每一档都只看结构字段，绝不读 message。
 *
 * 为什么是这个顺序：
 *  1. 过盾最先 —— CF 挑战是流量层拦截，别的都谈不上，上层还要靠它拉过盾流程。
 *  2. 「未登录」先于「服务端原因」—— Discourse 未登录时给的那句
 *     「您需要登录才能执行此操作。」本身也在响应体里，若先认原因，就把唯一可执行的引导
 *     （去登录）擦成了一句没有下文的话。
 *  3. 服务端原因先于状态码模板 —— 422 的校验文案说明了「踩了哪条」，比「没通过论坛校验」
 *     有用得多；而 statusCode===0 的本地校验拦截（「请至少选择一个类别。」）也走这一档，
 *     它压根没发请求，按 LOCAL_ABORT/NETWORK 说都是误导。
 *  4. 传输细分看 failureKind；没标的一律按「网络不顺畅」，不做字符串猜测。
 */
export function classifyFailure<T>(response: NetworkResult<T>): FailureCause {
  const error: NetworkError | undefined = response.error;

  if (challengeRequested(response, error)) {
    return FailureCause.CHALLENGE;
  }
  if (response.notLoggedIn === true) {
    // 只在桥按响应体判真时才走这一档。判不上时继续往下按状态码分类，免得把「撞限流」
    // 「被盾」说成「你没登录」—— 1.0.8 里「403 + Discourse-Logged-Out 什么都不清」
    // 同一课：误判成鉴权问题的代价是把「等 60 秒就好」升级成「强制重登」。
    return FailureCause.NEED_LOGIN;
  }
  if (userReasonOf(response).length > 0) {
    return FailureCause.USER_REASON;
  }

  const statusCode: number = response.statusCode;

  // 0 = 压根没拿到响应（超时、环境没就绪、没选论坛、本地拦下、注入脚本自己失败）。
  if (statusCode === 0) {
    const kind: NetworkFailureKind | undefined = error !== undefined ? error.failureKind : undefined;
    if (kind === NetworkFailureKind.NO_ACTIVE_SITE) {
      return FailureCause.NO_ACTIVE_SITE;
    }
    if (kind === NetworkFailureKind.HOST_NOT_READY) {
      return FailureCause.HOST_NOT_READY;
    }
    if (kind === NetworkFailureKind.LOCAL_ABORT) {
      return FailureCause.LOCAL_ABORT;
    }
    if (kind === NetworkFailureKind.SESSION_EXPIRED) {
      // 会话过期在「该做什么」上与 not_logged_in 是同一件事,共用一档文案。
      return FailureCause.NEED_LOGIN;
    }
    if (kind === NetworkFailureKind.CSRF_UNAVAILABLE) {
      // 这一次没读到令牌,但没有任何「会话已失效」的正面证据(挑战页 HTML、执行器卡死、
      // 429/5xx、cookie 仓正在读写)。按网络档引导重试;把人赶去重新登录只会白登出一次。
      return FailureCause.NETWORK;
    }
    return FailureCause.NETWORK;
  }

  if (statusCode === 401 || statusCode === 403) {
    return FailureCause.FORBIDDEN;
  }
  if (statusCode === 404) {
    return FailureCause.NOT_FOUND;
  }
  if (statusCode === 409) {
    return FailureCause.CONFLICT;
  }
  if (statusCode === 429) {
    return FailureCause.RATE_LIMIT;
  }
  if (statusCode === 400 || statusCode === 422) {
    return FailureCause.REJECTED;
  }
  if (statusCode >= 500) {
    return FailureCause.UPSTREAM;
  }
  if (statusCode >= 200 && statusCode < 300) {
    // 请求成功、响应读不出预期结构：多半是站点改版或插件裁剪了字段。
    return FailureCause.MALFORMED;
  }
  return FailureCause.UNKNOWN;
}

/** 界面文案。这是页面唯一该调的函数。 */
export function friendlyFailure<T>(response: NetworkResult<T>, copy: FailureCopy): string {
  const subject: string = copy.subject;
  const action: string = copy.action;
  const cause: FailureCause = classifyFailure<T>(response);
  // 只在 USER_REASON 这一档用得上。classify 已保证走到该档时它非空；这里仍判一次空串,
  // 是为了让「分类函数与文案函数各自解释同一字段」这件事不会变成一句空文案上屏
  // (空串在界面上等于「点了没反应」)。
  const reason: string = userReasonOf(response);

  switch (cause) {
    case FailureCause.CHALLENGE:
      return `${subject}${action}遇到访问验证，请稍后重试`;
    case FailureCause.USER_REASON:
      return reason.length > 0 ? reason : `${subject}${action}失败，请稍后重试`;
    case FailureCause.NO_ACTIVE_SITE:
      return '还没有选择论坛，请先添加论坛';
    case FailureCause.HOST_NOT_READY:
      // 请求环境（那台常驻隐藏 WebView）还在初始化。对用户它是「正在准备」，不是「坏了」。
      return '正在准备请求环境，请稍后重试';
    case FailureCause.NETWORK:
      return `${subject}${action}失败，请检查网络后重试`;
    case FailureCause.NEED_LOGIN:
      // 不拼 subject/action:服务端说 not_logged_in 时,真实情况就是「这枚凭据不再代表任何人」,
      // 该说的话与「正在做什么」无关。拼进去会产出「请先登录后再退出登录」这种句子
      // (退出登录这条路径上恰恰可能出现 403)。
      return '登录状态已失效，请重新登录';
    case FailureCause.NOT_FOUND:
      return `${subject}不存在或已被删除`;
    case FailureCause.CONFLICT:
      return `${subject}已被改动，请刷新后重试`;
    case FailureCause.RATE_LIMIT:
      return '操作太快了，请稍后再试';
    case FailureCause.REJECTED:
      return `${subject}没通过论坛校验，请检查后重试`;
    case FailureCause.FORBIDDEN:
      // 403 但不是「未登录」：游客/信任级别不够。别谎报成没登录，也别只说「失败」——
      // 说清是论坛的限制，用户才知道反复重试没用。
      return `论坛权限不足，无法${action}${subject}`;
    case FailureCause.UPSTREAM:
      return '论坛那边暂时出了问题，请稍后重试';
    case FailureCause.MALFORMED:
      return `${subject}暂时读不出来，请稍后重试`;
    case FailureCause.LOCAL_ABORT:
      return `${subject}${action}没发出去，请重试`;
    default:
      return `${subject}${action}失败，请稍后重试`;
  }
}

/**
 * 排查用的原文一行。界面不再显示 error.message，所以调用点必须把这行留在日志里，
 * 否则「网络快照」只剩探针结果，用户报「点了没反应」时无从下手。
 *
 * 刻意不含响应体：body 由桥层按详细日志开关自己转储，这里重复一次会把整页 HTML 抄进日志。
 */
export function rawFailure<T>(response: NetworkResult<T>): string {
  const error: NetworkError | undefined = response.error;
  const code: string = error !== undefined ? error.code : 'none';
  const kind: string = error !== undefined && error.failureKind !== undefined ? error.failureKind : '-';
  const message: string = error !== undefined ? error.message : '';
  return `code=${code} status=${response.statusCode} kind=${kind} challenge=${response.challengeState} errMsg=${message.length > 0 ? message : '(empty)'}`;
}

// Chromium/ArkWeb 的 net error 码。只列会在首屏真撞上的那几个,其余一律走通用兜底 ——
// 逐条穷举没有意义(用户看到的是「打不开」,不是错误码),但把最常见的四类分开说清
// 能让用户知道该做什么:改 DNS、换网络、等一会儿、还是证书有问题别输密码。
const NET_ERROR_TIMED_OUT: number = -7;
const NET_ERROR_CONNECTION_CLOSED: number = -100;
const NET_ERROR_CONNECTION_RESET: number = -101;
const NET_ERROR_CONNECTION_REFUSED: number = -102;
const NET_ERROR_NAME_NOT_RESOLVED: number = -105;
const NET_ERROR_INTERNET_DISCONNECTED: number = -106;
const NET_ERROR_ADDRESS_UNREACHABLE: number = -109;
const NET_ERROR_CONNECTION_TIMED_OUT: number = -118;
const NET_ERROR_CERT_COMMON_NAME_INVALID: number = -200;
const NET_ERROR_CERT_DATE_INVALID: number = -201;
const NET_ERROR_CERT_AUTHORITY_INVALID: number = -202;

/**
 * 网页加载失败的用户语言。
 *
 * 原先 WebViewPage 直接把 `WebResourceError.getErrorInfo()` 显示在错误页底部,用户读到的是
 * 「ERR_NAME_NOT_RESOLVED」这种引擎内部串。错误码仍要进日志(排查靠它),但界面得说人话。
 *
 * 返回的每句都带「下一步能做什么」——这类页面本来就没有重试之外的出口,不说清等于让用户干瞪眼。
 */
export function friendlyWebLoadFailure(errorCode: number): string {
  if (errorCode === NET_ERROR_NAME_NOT_RESOLVED) {
    // 本仓最主要的一条:linux.do 的 DNS 在国内被污染,DoH 没开时首屏必然解析失败。
    return '域名解析失败,请在设置里开启 DoH 后重试';
  }
  if (errorCode === NET_ERROR_INTERNET_DISCONNECTED) {
    return '当前没有网络连接,请检查 Wi-Fi 或移动数据';
  }
  if (errorCode === NET_ERROR_TIMED_OUT || errorCode === NET_ERROR_CONNECTION_TIMED_OUT) {
    return '连接超时,请检查网络后重试';
  }
  if (errorCode === NET_ERROR_CONNECTION_REFUSED || errorCode === NET_ERROR_ADDRESS_UNREACHABLE) {
    return '连不上这个地址,可能需要代理才能访问';
  }
  if (errorCode === NET_ERROR_CONNECTION_RESET || errorCode === NET_ERROR_CONNECTION_CLOSED) {
    // linux.do 在 CF 边缘会间歇性 RST,重试通常就好 —— 这句要明确说「可以再试一次」。
    return '连接被中断,请稍后重试';
  }
  if (errorCode === NET_ERROR_CERT_COMMON_NAME_INVALID || errorCode === NET_ERROR_CERT_DATE_INVALID ||
    errorCode === NET_ERROR_CERT_AUTHORITY_INVALID) {
    // 证书错误时绝不能引导用户「继续访问」:那正是中间人攻击的样子。
    return '这个网站的安全证书有问题,为安全起见已停止加载';
  }
  return '页面打不开,请检查网络后重试';
}
