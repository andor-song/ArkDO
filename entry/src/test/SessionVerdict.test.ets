import { describe, it, expect } from '@ohos/hypium';
import { ChallengeState } from '../main/ets/services/network/NetworkTypes';
import { CookiePresence } from '../main/ets/services/web/CookieProbe';
import {
  isTokenDeclaredDead,
  judgeSession,
  nextAnonymousStrikes,
  shouldApplyAnonymous
} from '../main/ets/services/auth/SessionVerdict';

export default function sessionVerdictTest() {
  describe('sessionVerdictTest', () => {
    it('challengeBeatsEverything', 0, () => {
      expect(judgeSession({
        transportOk: true, statusCode: 403, challengeState: ChallengeState.REQUIRED,
        cookiePresence: CookiePresence.PRESENT, userPayloadPresent: false
      })).assertEqual('unknown');
    });

    it('loggedInWhenTransportOkAndUserPayloadPresent', 0, () => {
      expect(judgeSession({
        transportOk: true, statusCode: 200, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.PRESENT, userPayloadPresent: true
      })).assertEqual('logged-in');
    });

    it('confirmedAnonymousWhenServerSaysNoUser', 0, () => {
      expect(judgeSession({
        transportOk: true, statusCode: 200, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.PRESENT, userPayloadPresent: false
      })).assertEqual('anonymous-confirmed');
    });

    // 真机日志（2026-10-14 07:35:11）：同一秒内 loggedIn=true 而 authCookiePresent=false ——
    // `_t` 探测在**已登录**时也会报「没有」，所以 404+ABSENT 不足以确认登出，必须降级为第二振。
    it('treats404WithAbsentCookieAsUnconfirmedBecauseProbeLies', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.ABSENT, userPayloadPresent: false
      })).assertEqual('anonymous-unconfirmed');
    });

    it('unconfirmedAnonymousWhen404AndCookieProbeUnknown', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.UNKNOWN, userPayloadPresent: false
      })).assertEqual('anonymous-unconfirmed');
    });

    it('treats404WithPresentCookieAsUnconfirmedToo', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.PRESENT, userPayloadPresent: false
      })).assertEqual('anonymous-unconfirmed');
    });

    it('unknownForServerErrorsAndTransportFailures', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 500, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.ABSENT, userPayloadPresent: false
      })).assertEqual('unknown');
      expect(judgeSession({
        transportOk: false, statusCode: 0, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.ABSENT, userPayloadPresent: false
      })).assertEqual('unknown');
    });

    it('confirmedAnonymousAppliesOnFirstStrike', 0, () => {
      expect(shouldApplyAnonymous('anonymous-confirmed', 0)).assertTrue();
      expect(nextAnonymousStrikes('anonymous-confirmed', 3)).assertEqual(0);
    });

    it('unconfirmedAnonymousNeedsSecondStrike', 0, () => {
      expect(shouldApplyAnonymous('anonymous-unconfirmed', 0)).assertFalse();
      expect(shouldApplyAnonymous('anonymous-unconfirmed', 1)).assertTrue();
      expect(nextAnonymousStrikes('anonymous-unconfirmed', 0)).assertEqual(1);
      expect(nextAnonymousStrikes('anonymous-unconfirmed', 1)).assertEqual(2);
    });

    it('anyOtherVerdictResetsStrikes', 0, () => {
      expect(shouldApplyAnonymous('logged-in', 5)).assertFalse();
      expect(shouldApplyAnonymous('unknown', 5)).assertFalse();
      expect(nextAnonymousStrikes('logged-in', 2)).assertEqual(0);
      expect(nextAnonymousStrikes('unknown', 2)).assertEqual(0);
    });

    // ---- 2026-10-27：服务端正面证据 `Discourse-Logged-Out` 参与判定 ----

    // 404 + 该头 = 服务端查过这枚令牌且查不到 → 一次即清，不必第二振。
    it('404WithServerRejectionHeaderConfirmsLogoutAtOnce', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.PRESENT, userPayloadPresent: false,
        serverRejectedToken: true
      })).assertEqual('anonymous-confirmed');
      expect(shouldApplyAnonymous('anonymous-confirmed', 0)).assertTrue();
    });

    // 404 而**没有**该头：多半是本机没带 cookie（令牌其实还活着）——继续要两振，
    // 这条正是 1.0.6「冷启动靠备份自愈」所依赖的宽松判定，不能因为加了新判据而被削掉。
    it('404WithoutHeaderStillNeedsSecondStrike', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.ABSENT, userPayloadPresent: false,
        serverRejectedToken: false
      })).assertEqual('anonymous-unconfirmed');
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.UNKNOWN, userPayloadPresent: false
      })).assertEqual('anonymous-unconfirmed');
    });

    // 挑战态优先于一切：CF 的 404 壳子照样不能当登出。
    it('challengeStillBeatsRejectionHeader', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.REQUIRED,
        cookiePresence: CookiePresence.ABSENT, userPayloadPresent: false,
        serverRejectedToken: true
      })).assertEqual('unknown');
    });

    // 403 + 同一个头是**本机撞上按 IP 的 cookie_auth 限流**（服务端连查都没查），
    // 令牌可能仍然有效 → unknown：既不清登录态，也绝不能据此销毁备份。
    it('403WithRejectionHeaderIsThrottlingNotDeath', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 403, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.PRESENT, userPayloadPresent: false,
        serverRejectedToken: true
      })).assertEqual('unknown');
    });

    // 上层「要不要烧备份」与 verdict 必须同一个口径：只认 404。
    // 两处判断漂开就会留下「清了登录态却没清备份」的半清理状态 —— 死令牌重放的入口。
    it('tokenDeathPredicateOnlyAcceptsNotFound', 0, () => {
      expect(isTokenDeclaredDead(404, true)).assertTrue();
      expect(isTokenDeclaredDead(403, true)).assertFalse();
      expect(isTokenDeclaredDead(401, true)).assertFalse();
      expect(isTokenDeclaredDead(500, true)).assertFalse();
      expect(isTokenDeclaredDead(404, false)).assertFalse();
      expect(isTokenDeclaredDead(404, undefined)).assertFalse();
    });
  });
}
