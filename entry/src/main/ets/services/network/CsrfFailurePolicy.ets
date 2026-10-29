import { NetworkFailureKind } from './NetworkTypes';

// CSRF 读取失败的处理策略。抽成纯模块的理由:策略本身(重试几次、缓存多久、
// 什么才算「会话真的过期」)是判断逻辑,必须能单测;而真正执行它的代码是注入到
// ArkWeb 里的 JS 字符串(CsrfScriptTemplate),只能靠子串断言。
//
// 背景(真机日志 2026-10-29 00:03→00:17):13 条 `csrf source=none` 里,同一分钟
// 的草稿保存与 2.5 秒后的 /clicks/track 都是 `source=session` 且 200 —— 令牌明明还在,
// 只是那一次没读到。旧实现把「读失败」直接判成 session_expired,于是:
//   1) 界面引导用户重新登录(白登出一次);
//   2) 已读上报按 status=0 退避重试 4 档后整批丢弃(主题 3046615/3024844 的进度永久缺块)。
// 读失败的真实原因里,CF 挑战页返回 HTML(r.json() 抛错)与宿主执行器卡死(问题 3)
// 都占了大头,两者都与会话无关。

// 重试间隔(ms)。第一次立即读(令牌通常就在 cookie 仓里,不该为它加延迟),
// 之后 300ms / 900ms 各再读一次:覆盖「cookie 仓正在读写」与「挑战页刚切走」这类
// 亚秒级抖动,同时把最坏新增延迟压在 1.2s 内 —— 写请求本来就有 15s 超时预算。
export const CSRF_RETRY_DELAYS_MS: number[] = [0, 300, 900];

// 最近一次成功令牌的复用窗口。缓存要覆盖的是「这一次没读到」的秒级抖动,不是几分钟的断网:
// 窗口越长,越可能跨过一次 `_t` 轮换,拿旧会话的令牌去发写请求(会 403 BAD CSRF)。
// 2 分钟足够覆盖 cookie 仓读写冲突/挑战页刚切走这类场景,又把陈旧风险压到很低。
export const CSRF_CACHE_TTL_MS: number = 2 * 60 * 1000;

/**
 * 把「这一次没读到 CSRF」的现场事实分类成给用户看的失败档位。
 *
 * 只有**正面证据**才算会话过期:
 *  - 响应带 `discourse-logged-out`(服务端明确说本次凭据已失效);
 *  - HTTP 401;
 *  - HTTP 403 且**不是** CF 挑战(`cf-mitigated` 为空)。Discourse 对匿名用户读
 *    /session/csrf.json 正是回 403;而 CF 挑战也回 403,带 `cf-mitigated: challenge`,
 *    那种情况是「盾挡着」,重新登录毫无用处。
 *
 * 其余(传输失败、超时、5xx、429、挑战页 HTML 解析失败、字段缺失)一律 transient:
 * 按网络档提示「稍后重试」,而不是把用户赶去重新登录。
 */
export function classifyCsrfFailure(loggedOut: boolean, httpStatus: number, cfMitigated: boolean): NetworkFailureKind {
  if (loggedOut) {
    return NetworkFailureKind.SESSION_EXPIRED;
  }
  if (httpStatus === 401) {
    return NetworkFailureKind.SESSION_EXPIRED;
  }
  if (httpStatus === 403 && !cfMitigated) {
    return NetworkFailureKind.SESSION_EXPIRED;
  }
  return NetworkFailureKind.CSRF_UNAVAILABLE;
}
