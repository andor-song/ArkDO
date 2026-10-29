import { describe, it, expect } from '@ohos/hypium';
import { buildCsrfScript } from '../main/ets/services/network/webscript/CsrfScriptTemplate';
import { createFormScript } from '../main/ets/services/network/ArkWebFetchScriptFactory';

function sampleScript(): string {
  return buildCsrfScript({
    requestIdToken: 'ARKDO_REQUEST_ID',
    urlExpr: "'/topics/timings'",
    methodExpr: "'POST'",
    headerLines: [
      "'Accept': '*/*'",
      "'X-CSRF-Token': csrf"
    ],
    prelude: '',
    bodyExpr: "'a=1'",
    referrerExpr: "'https://linux.do/t/1'"
  });
}

export default function csrfScriptTemplateTest() {
  describe('csrfScriptTemplateTest', () => {
    it('retriesCsrfReadWithBackoffInsteadOfTwoImmediateTries', 0, () => {
      const script: string = sampleScript();

      // 旧实现是「读一次失败 → 立刻再读一次」,两次都撞在同一个亚秒级抖动上。
      // 现在按 [0,300,900] 退避,且第一次不额外加延迟。
      expect(script).assertContain('const delays = [0,300,900]');
      expect(script).assertContain('await sleep(delays[i])');
      expect(script).assertContain('csrfAttempts += 1');
    });

    it('recordsWhyTheReadFailedInsteadOfCollapsingToEmptyString', 0, () => {
      const script: string = sampleScript();

      // 四类现场必须可分辨:HTTP 非 2xx、挑战页 HTML、JSON 里没有 csrf、传输层抛错。
      expect(script).assertContain("csrfLastError = 'http_' + r.status");
      expect(script).assertContain("csrfLastError = 'malformed'");
      expect(script).assertContain("csrfLastError = 'missing'");
      expect(script).assertContain("csrfLastError = 'transport:'");
      // 现场事实随回执上报,分类在 ArkTS 侧做。
      expect(script).assertContain('csrfAttempts: csrfAttempts');
      expect(script).assertContain('csrfLastStatus: csrfLastStatus');
      expect(script).assertContain('csrfCfMitigated: csrfCfMitigated');
      expect(script).assertContain('csrfLoggedOut: csrfLoggedOut');
    });

    it('reusesLastGoodTokenBeforeFallingBackToMeta', 0, () => {
      const script: string = sampleScript();

      expect(script).assertContain('window.__arkdoCsrfCache');
      expect(script).assertContain("csrfSource = 'cache'");
      expect(script).assertContain('csrfUsedCache = true');
      // 只有明确登出才清缓存 —— 挑战/抖动期间缓存是唯一还能救回写请求的东西。
      expect(script).assertContain('window.__arkdoCsrfCache = null');
      // meta 仍是最后的兜底。
      expect(script).assertContain('csrf = metaCsrf()');
    });

    it('neverReportsSessionExpiredOnItsOwn', 0, () => {
      const script: string = sampleScript();

      // 脚本只报现场,不再自行断言「会话过期」—— 旧文案把用户直接赶去重登。
      expect(script).assertContain("'csrf_unavailable'");
      expect(script.includes("'session_expired'")).assertFalse();
      expect(script.includes('please re-login')).assertFalse();
    });

    it('stopsRetryingOnlyOnExplicitLogoutEvidence', 0, () => {
      const script: string = sampleScript();

      expect(script).assertContain('const definiteLogout = () => {');
      expect(script).assertContain('csrfLastStatus === 403 && csrfCfMitigated.length === 0');
      expect(script).assertContain('if (definiteLogout()) {');
    });

    it('doesNotReuseCacheOrEmitSecondCallbackAfterFailFast', 0, () => {
      const script: string = sampleScript();

      // 明确登出时缓存必须作废,否则会拿一个注定 403 的令牌去发写请求。
      expect(script).assertContain('if (csrf && !definiteLogout())');
      // fail-fast 之后主链会以 undefined 继续走 response 分支,没有这道闸就会再回一个
      // 「TypeError: Cannot read properties of undefined」的失败回执。
      expect(script).assertContain('if (!response) {');
    });

    it('keepsCsrfHeaderAndRequestSkeletonIntact', 0, () => {
      const script: string = createFormScript('POST', '/topics/timings', 'a=1', 'https://linux.do/t/1');

      // header 的顺序与内容承重(CF 看指纹),重构不能顺手重排。
      const csrfHeaderAt: number = script.indexOf("'X-CSRF-Token': csrf");
      const acceptAt: number = script.indexOf("'Accept': '*/*'");
      expect(acceptAt >= 0).assertTrue();
      expect(csrfHeaderAt > acceptAt).assertTrue();
      expect(script).assertContain("'Discourse-Present': 'true'");
      expect(script).assertContain("'Discourse-Background': 'true'");
      expect(script).assertContain('body: "a=1"');
      expect(script).assertContain("fetchOptions.referrerPolicy = 'strict-origin-when-cross-origin'");
    });
  });
}
