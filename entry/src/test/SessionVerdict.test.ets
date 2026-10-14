import { describe, it, expect } from '@ohos/hypium';
import { ChallengeState } from '../main/ets/services/network/NetworkTypes';
import { CookiePresence } from '../main/ets/services/web/CookieProbe';
import { judgeSession, nextAnonymousStrikes, shouldApplyAnonymous } from '../main/ets/services/auth/SessionVerdict';

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

    it('confirmedAnonymousWhen404AndCookieAbsent', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.ABSENT, userPayloadPresent: false
      })).assertEqual('anonymous-confirmed');
    });

    it('unconfirmedAnonymousWhen404AndCookieProbeUnknown', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.UNKNOWN, userPayloadPresent: false
      })).assertEqual('anonymous-unconfirmed');
    });

    it('unknownWhen404ButCookieStillPresent', 0, () => {
      expect(judgeSession({
        transportOk: false, statusCode: 404, challengeState: ChallengeState.NONE,
        cookiePresence: CookiePresence.PRESENT, userPayloadPresent: false
      })).assertEqual('unknown');
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
  });
}
