// 会话判定的纯逻辑层：把「这次 /session/current.json 的响应说明什么」收敛成四态，
// 并把「要不要据此清掉登录态」的迟滞策略也放在这里（纯函数，无副作用，可单测）。
//
// 背景（见 docs/superpowers/specs/2026-10-14-session-resilience-design.md）：
// Discourse 对匿名会话回 404 + 空 body。旧实现把「404 且探测不到 `_t`」直接当「确认登出」，
// 而 cookie 探测本身会 fail-open（异常 → 当成没有 cookie），于是一次探测抖动就能把用户掀下线，
// 且清掉之后不再自愈。现在：
//   · 只有**服务端正面证据**（2xx 且明确没有 current_user）或「404 且明确没有 `_t`」才一次即清；
//   · cookie 探测不确定时降级为 anonymous-unconfirmed，需要**两振**才清（策略 B）；
//   · 挑战态 / 5xx / 传输失败一律 unknown —— 保留登录态。
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
}

// 未登录时 /session/current.json 的状态码（Discourse SessionController#current）。
const CURRENT_SESSION_ANONYMOUS_STATUS: number = 404;

export function judgeSession(signals: SessionSignals): SessionVerdict {
  // CF 挑战优先：哪怕 status 是 404 也可能是挑战壳子，绝不能当登出。
  if (signals.challengeState !== ChallengeState.NONE) {
    return 'unknown';
  }
  if (signals.transportOk) {
    return signals.userPayloadPresent ? 'logged-in' : 'anonymous-confirmed';
  }
  if (signals.statusCode === CURRENT_SESSION_ANONYMOUS_STATUS) {
    if (signals.cookiePresence === CookiePresence.ABSENT) {
      return 'anonymous-confirmed';
    }
    if (signals.cookiePresence === CookiePresence.UNKNOWN) {
      return 'anonymous-unconfirmed';
    }
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
