// 会话判定的纯逻辑层：把「这次 /session/current.json 的响应说明什么」收敛成四态，
// 并把「要不要据此清掉登录态」的迟滞策略也放在这里（纯函数，无副作用，可单测）。
//
// 背景（见 docs/superpowers/specs/2026-10-14-session-resilience-design.md）：
// Discourse 对匿名会话回 404 + 空 body。旧实现把「404 且探测不到 `_t`」直接当「确认登出」，
// 而 cookie 探测本身会 fail-open（异常 → 当成没有 cookie），于是一次探测抖动就能把用户掀下线，
// 且清掉之后不再自愈。1.0.6 修成：
//   · 只有**服务端正面证据**（2xx 且明确没有 current_user）才一次即清；
//   · 404 一律降级为 anonymous-unconfirmed，需要**两振**才清（策略 B）；
//   · 挑战态 / 5xx / 传输失败一律 unknown —— 保留登录态。
//
// ## 2026-10-27：404 不再「一律只算不确定」
// 「404」把两种截然不同的事实压成了同一个结论：
//   (a) 这台设备本来就是游客（cookie 丢了 / 还没登录过）；
//   (b) 这台设备带的令牌**已被服务端查过且查不到**（上游置了 BAD_TOKEN）。
// 上游对 (b) 会额外回响应头 `Discourse-Logged-Out: 1`（lib/hijack.rb:95 与
// lib/middleware/request_tracker.rb:410，两处都由 BAD_TOKEN 触发）。因此
// **404 + 该头 = 正面证据**，直接确认登出，不必再靠「cookie 探测」这种在真机上会说谎的
// 旁证去猜（1.0.6 的修复记录里就写着：已登录时 hasCookie('_t') 也会报 absent）。
// 反过来，**404 而没有该头**恰恰偏向 (a)：令牌可能还活得好好的，只是本机 cookie 仓里没有
// —— 那正是「把备份写回去就能救回来」的情形，绝不能升级成确认登出。
//
// ## 同一把限流锁为什么会牵连同一条 Wi-Fi 上的另一台设备
// default_current_user_provider.rb:138 那把锁的 key 是 `cookie_auth_#{request.ip}`
// ——**按 IP**，且只有「带了认证 cookie 却没认出人」才计数。本机若揣着一枚死令牌反复请求，
// 就会把它刷满；刷满后服务端连查都不查，直接 `raise InvalidAccess(delete_cookie: TOKEN_COOKIE)`
// → **403** + 同一个头 + 删本机 cookie。于是同一网络里电脑浏览器那枚**有效**的令牌也会撞上
// 同一把闸被删 —— 用户看到的就是「手机登录顶掉电脑，反过来也是」。
//
// 这条 403 在本函数里走最后一行 `return 'unknown'`（既不是 2xx 也不是 404），**什么都不清**。
// 这是刻意的：限流下的令牌可能仍然有效，把它当死令牌销毁就等于把「等 60 秒就好」升级成
// 「强制重登」，而被冤枉的正是这一端。所以 isTokenDeclaredDead 只认 404。
import { ChallengeState } from '../network/NetworkTypes';
import { CookiePresence } from '../web/CookieProbe';

export type SessionVerdict = 'logged-in' | 'anonymous-confirmed' | 'anonymous-unconfirmed' | 'unknown';

export interface SessionSignals {
  // 传输与 HTTP 层成功（2xx 且响应体解析成功）。
  transportOk: boolean;
  statusCode: number;
  challengeState: ChallengeState;
  cookiePresence: CookiePresence;
  // 响应体里确实带了 current_user 对象。
  userPayloadPresent: boolean;
  // 响应带 `Discourse-Logged-Out: 1`：服务端拒绝本次携带的认证令牌。
  // undefined（旧信号构造点、未回该头的服务端）一律按「没有该证据」处理。
  serverRejectedToken?: boolean;
}

// 未登录时 /session/current.json 的状态码（Discourse SessionController#current）。
const CURRENT_SESSION_ANONYMOUS_STATUS: number = 404;

/**
 * 「服务端明说这枚认证令牌已经作废」的判据：404 + `Discourse-Logged-Out`。
 *
 * 单独抽成导出的纯函数，是因为上层（RootTabPage）需要**同一个口径**决定要不要销毁本地备份：
 * 两处各写一遍的话，迟早会漂出「界面判登出但备份还留着」这类半清理状态 —— 那正是死令牌
 * 被反复灌回去重放的入口。
 *
 * 刻意不含 403：403 + 该头是**本机撞上按 IP 的限流**，不是令牌失效（见文件头），
 * 按死令牌处置会误删有效凭据。
 */
export function isTokenDeclaredDead(statusCode: number, serverRejected: boolean | undefined): boolean {
  return serverRejected === true && statusCode === CURRENT_SESSION_ANONYMOUS_STATUS;
}

export function judgeSession(signals: SessionSignals): SessionVerdict {
  // CF 挑战优先：哪怕 status 是 404 也可能是挑战壳子，绝不能当登出。
  if (signals.challengeState !== ChallengeState.NONE) {
    return 'unknown';
  }
  if (signals.transportOk) {
    return signals.userPayloadPresent ? 'logged-in' : 'anonymous-confirmed';
  }
  if (signals.statusCode === CURRENT_SESSION_ANONYMOUS_STATUS) {
    // 服务端亲口说「这枚我查过、没有」→ 确认登出，不需要第二振。
    if (signals.serverRejectedToken === true) {
      return 'anonymous-confirmed';
    }
    // 没有该头的 404 什么也证明不了：可能是死令牌（服务端没回该头），更可能是本机压根
    // 没带 cookie（令牌其实还活着，1.0.6 的真机日志就是这一类）。继续要两振。
    return 'anonymous-unconfirmed';
  }
  return 'unknown';
}

// 连续匿名振数：只有 unconfirmed 累加，其它任何结论都清零（含登录成功与真匿名落地）。
export function nextAnonymousStrikes(verdict: SessionVerdict, priorStrikes: number): number {
  if (verdict === 'anonymous-unconfirmed') {
    return priorStrikes + 1;
  }
  return 0;
}

// 策略 B：服务端正面证据（confirmed）一次即清；探测不确定（unconfirmed）要第二次才清。
export function shouldApplyAnonymous(verdict: SessionVerdict, priorStrikes: number): boolean {
  if (verdict === 'anonymous-confirmed') {
    return true;
  }
  if (verdict === 'anonymous-unconfirmed') {
    return priorStrikes >= 1;
  }
  return false;
}
