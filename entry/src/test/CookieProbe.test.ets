import { describe, it, expect } from '@ohos/hypium';
import {
  CookiePresence,
  NO_COOKIE,
  containsCookie,
  cookieValueFromHeader,
  credentialFingerprint,
  presenceFromHeader
} from '../main/ets/services/web/CookieProbe';

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

    // 冷启动写回需要**取到值**(不仅是存在性),且值里可能含 '='(base64 padding)。
    it('extractsCookieValueKeepingEqualsSigns', 0, () => {
      expect(cookieValueFromHeader('a=1; _t=abc==; b=2', '_t')).assertEqual('abc==');
      expect(cookieValueFromHeader('_t=v1', '_t')).assertEqual('v1');
    });

    it('returnsUndefinedWhenCookieValueMissingOrEmpty', 0, () => {
      expect(cookieValueFromHeader('a=1; b=2', '_t')).assertUndefined();
      expect(cookieValueFromHeader('_t=', '_t')).assertUndefined();
      expect(cookieValueFromHeader(undefined, '_t')).assertUndefined();
    });

    // ---- 凭据指纹：日志要能分辨「换了一枚」与「还是那枚」，又绝不能出现原值 ----

    it('fingerprintIsStableAndDistinguishesValues', 0, () => {
      expect(credentialFingerprint('abc123')).assertEqual(credentialFingerprint('abc123'));
      expect(credentialFingerprint('abc123') === credentialFingerprint('abc124')).assertFalse();
    });

    // 缺失值必须是固定占位符而不是某个真实哈希：调用方拿它判「没有凭据」，
    // 而「死令牌名单」要求空值**永不匹配**（否则一次误记就把恢复链路焊死一辈子）。
    it('fingerprintOfMissingValueIsThePlaceholder', 0, () => {
      expect(credentialFingerprint(undefined)).assertEqual(NO_COOKIE);
      expect(credentialFingerprint('')).assertEqual(NO_COOKIE);
    });

    // 定长 8 位十六进制（进日志好对齐、也够挡碰撞），且不泄漏输入的任何片段。
    it('fingerprintIsFixedLengthHexAndDoesNotLeakInput', 0, () => {
      const secret: string = 'abcdefghij1234567890-hide-me';
      const printed: string = credentialFingerprint(secret);
      expect(printed.length).assertEqual(8);
      expect(printed.indexOf('1234567890') < 0).assertTrue();
      expect(credentialFingerprint('x'.repeat(3000)).length).assertEqual(8);
    });
  });
}
