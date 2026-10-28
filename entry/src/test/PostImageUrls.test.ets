import { describe, it, expect } from '@ohos/hypium';
import { collectPostImageUrls } from '../main/ets/services/content/PostImageUrls';

export default function postImageUrlsTest() {
  describe('postImageUrlsTest', () => {
    // 图片墙按楼层顺序左右滑,顺序与去重都要稳。
    it('collectsImageSrcInOrderAndDedupes', 0, () => {
      const html: string = '<p>a</p><img src="https://linux.do/uploads/a.png" alt="a">' +
        '<img class="d-image" src="https://linux.do/uploads/b.jpg">' +
        '<img src="https://linux.do/uploads/a.png">';
      expect(collectPostImageUrls(html).join(',')).assertEqual(
        'https://linux.do/uploads/a.png,https://linux.do/uploads/b.jpg');
    });

    // emoji 是文字不是配图;data: 内联图不整屏显示。
    it('skipsEmojiAndInlineDataImages', 0, () => {
      const html: string = '<img src="/images/emoji/apple/1f600.png" class="emoji">' +
        '<img class="emoji" src="https://linux.do/uploads/x.png">' +
        '<img src="data:image/png;base64,AAAA">' +
        '<img src="https://linux.do/uploads/real.png">';
      expect(collectPostImageUrls(html).join(',')).assertEqual('https://linux.do/uploads/real.png');
    });

    it('decodesHtmlEntitiesInSrc', 0, () => {
      const html: string = '<img src="https://linux.do/uploads/a.png?x=1&amp;y=2">';
      expect(collectPostImageUrls(html)[0]).assertEqual('https://linux.do/uploads/a.png?x=1&y=2');
    });

    it('returnsEmptyForPlainText', 0, () => {
      expect(collectPostImageUrls('').length).assertEqual(0);
      expect(collectPostImageUrls('<p>没有图</p>').length).assertEqual(0);
      expect(collectPostImageUrls('<img alt="no src">').length).assertEqual(0);
    });
  });
}
