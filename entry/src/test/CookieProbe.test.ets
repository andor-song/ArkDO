import { describe, it, expect } from '@ohos/hypium';
import { CookiePresence, containsCookie, presenceFromHeader } from '../main/ets/services/web/CookieProbe';

export default function cookieProbeTest() {
  describe('cookieProbeTest', () => {
    it('absentWhenHeaderEmpty', 0, () => {
      expect(presenceFromHeader('', '_t')).assertEqual(CookiePresence.ABSENT);
    });

    it('presentWhenCookieListed', 0, () => {
      expect(presenceFromHeader('a=1; _t=xyz; b=2', '_t')).assertEqual(CookiePresence.PRESENT);
    });

    it('presentWhenCookieIsFirstOrLastToken', 0, () => {
      expect(presenceFromHeader('_t=xyz; b=2', '_t')).assertEqual(CookiePresence.PRESENT);
      expect(presenceFromHeader('a=1; _t=xyz', '_t')).assertEqual(CookiePresence.PRESENT);
    });

    it('absentWhenOtherCookiesOnly', 0, () => {
      expect(presenceFromHeader('a=1; b=2', '_t')).assertEqual(CookiePresence.ABSENT);
    });

    it('unknownWhenHeaderMissing', 0, () => {
      expect(presenceFromHeader(undefined, '_t')).assertEqual(CookiePresence.UNKNOWN);
    });

    it('doesNotMatchSubstring', 0, () => {
      expect(presenceFromHeader('_tx=1; foo_t=2', '_t')).assertEqual(CookiePresence.ABSENT);
    });

    it('toleratesWhitespace', 0, () => {
      expect(presenceFromHeader('  _t=abc  ', '_t')).assertEqual(CookiePresence.PRESENT);
      expect(containsCookie('  _t=abc  ', '_t')).assertTrue();
    });
  });
}
