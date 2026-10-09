import { describe, it, expect } from '@ohos/hypium';
import { LinkRouter, LinkTargetKind } from '../main/ets/services/content/LinkRouter';

export default function linkRouterTest() {
  describe('linkRouterTest', () => {
    it('keepsExternalHttpAsWeb', 0, () => {
      const target = LinkRouter.resolve('https://example.com/page');
      expect(target.kind).assertEqual(LinkTargetKind.WEB);
      expect(target.url).assertEqual('https://example.com/page');
    });

    it('rejectsJavascriptSchemeWithEmptyUrl', 0, () => {
      const target = LinkRouter.resolve('javascript:alert(1)');
      expect(target.kind).assertEqual(LinkTargetKind.WEB);
      expect(target.url).assertEqual('');
    });

    it('rejectsDataScheme', 0, () => {
      const target = LinkRouter.resolve('data:text/html,<script>x</script>');
      expect(target.url).assertEqual('');
    });

    it('keepsEmptyUrlAsWebWithEmptyUrl', 0, () => {
      const target = LinkRouter.resolve('');
      expect(target.kind).assertEqual(LinkTargetKind.WEB);
      expect(target.url).assertEqual('');
    });
  });
}
