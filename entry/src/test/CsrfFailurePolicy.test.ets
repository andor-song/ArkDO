import { describe, it, expect } from '@ohos/hypium';
import { CSRF_CACHE_TTL_MS, CSRF_RETRY_DELAYS_MS, classifyCsrfFailure } from '../main/ets/services/network/CsrfFailurePolicy';
import { NetworkFailureKind } from '../main/ets/services/network/NetworkTypes';

export default function csrfFailurePolicyTest() {
  describe('csrfFailurePolicyTest', () => {
    it('treatsOnlyExplicitLogoutEvidenceAsSessionExpired', 0, () => {
      // 服务端明确说凭据失效:唯一无争议的一条。
      expect(classifyCsrfFailure(true, 200, false)).assertEqual(NetworkFailureKind.SESSION_EXPIRED);
      expect(classifyCsrfFailure(false, 401, false)).assertEqual(NetworkFailureKind.SESSION_EXPIRED);
      // 匿名用户读 /session/csrf.json 时 Discourse 回 403;没有 CF 头就是真的没登录。
      expect(classifyCsrfFailure(false, 403, false)).assertEqual(NetworkFailureKind.SESSION_EXPIRED);
    });

    it('doesNotBlameSessionForChallengeOrTransportFailures', 0, () => {
      // CF 挑战也回 403,但带 cf-mitigated —— 重新登录毫无用处。
      expect(classifyCsrfFailure(false, 403, true)).assertEqual(NetworkFailureKind.CSRF_UNAVAILABLE);
      // 传输失败(status 0)、限流、上游 5xx:都只是「这一次没读到」。
      expect(classifyCsrfFailure(false, 0, false)).assertEqual(NetworkFailureKind.CSRF_UNAVAILABLE);
      expect(classifyCsrfFailure(false, 429, false)).assertEqual(NetworkFailureKind.CSRF_UNAVAILABLE);
      expect(classifyCsrfFailure(false, 502, false)).assertEqual(NetworkFailureKind.CSRF_UNAVAILABLE);
      // 挑战页是 HTML,JSON 解析失败时 lastStatus 可能是 200 —— 同样不能算过期。
      expect(classifyCsrfFailure(false, 200, false)).assertEqual(NetworkFailureKind.CSRF_UNAVAILABLE);
    });

    it('keepsRetryDelaysBoundedAndProgressive', 0, () => {
      // 第一次立即读:令牌通常就在 cookie 仓里,不该为它加延迟。
      expect(CSRF_RETRY_DELAYS_MS[0]).assertEqual(0);
      expect(CSRF_RETRY_DELAYS_MS.length).assertEqual(3);
      for (let i: number = 1; i < CSRF_RETRY_DELAYS_MS.length; i++) {
        expect(CSRF_RETRY_DELAYS_MS[i] > CSRF_RETRY_DELAYS_MS[i - 1]).assertTrue();
      }
      // 最坏新增延迟必须明显小于写请求的 15s 超时预算,否则重试本身就成了卡顿源。
      let total: number = 0;
      for (let i: number = 0; i < CSRF_RETRY_DELAYS_MS.length; i++) {
        total += CSRF_RETRY_DELAYS_MS[i];
      }
      expect(total < 2000).assertTrue();
    });

    it('boundsCacheReuseWindow', 0, () => {
      // 太短盖不住一次挑战/执行器抖动,太长会把过期会话的令牌留到重登之后。
      expect(CSRF_CACHE_TTL_MS >= 60 * 1000).assertTrue();
      expect(CSRF_CACHE_TTL_MS <= 30 * 60 * 1000).assertTrue();
    });
  });
}
