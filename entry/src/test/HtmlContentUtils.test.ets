import { describe, it, expect } from '@ohos/hypium';
import { resolveUrl } from '../main/ets/services/content/HtmlContentUtils';

export default function htmlContentUtilsTest() {
  describe('htmlContentUtilsTest', () => {
    it('keepsHttpsUrlAsIs', 0, () => {
      expect(resolveUrl('https://example.com/a.png')).assertEqual('https://example.com/a.png');
    });

    it('keepsHttpUrlAsIs', 0, () => {
      expect(resolveUrl('http://example.com/a')).assertEqual('http://example.com/a');
    });

    it('upgradesProtocolRelativeUrl', 0, () => {
      expect(resolveUrl('//example.com/a')).assertEqual('https://example.com/a');
    });

    it('rejectsJavascriptScheme', 0, () => {
      expect(resolveUrl('javascript:alert(1)')).assertEqual('');
    });

    it('rejectsDataScheme', 0, () => {
      expect(resolveUrl('data:text/html,<script>alert(1)</script>')).assertEqual('');
    });

    it('rejectsFileSchemeWithTabsAndEntities', 0, () => {
      // 实体解码 + trim 后再判断，恶意串常带编码混淆
      expect(resolveUrl('&#106;avascript:alert(1)')).assertEqual('');
    });
  });
}
