import { describe, it, expect } from '@ohos/hypium';
import { parseTagInput, sameTagNames } from '../main/ets/services/topic/TopicMetadata';

export default function topicMetadataTest() {
  describe('topicMetadataTest', () => {
    // 手机中文输入法默认打出全角逗号；只认半角会让用户「明明隔开了却只算一个标签」。
    it('acceptsBothFullWidthAndHalfWidthCommas', 0, () => {
      expect(parseTagInput('求助，linux,水').join('|')).assertEqual('求助|linux|水');
    });

    it('trimsAndDropsEmptyEntries', 0, () => {
      expect(parseTagInput('  求助 ,,  linux  , ').join('|')).assertEqual('求助|linux');
      expect(parseTagInput('').length).assertEqual(0);
      expect(parseTagInput('   ').length).assertEqual(0);
    });

    // 服务端对重复标签会报错，而用户看不出自己重复了 —— 客户端先去重（保序）。
    it('deduplicatesKeepingFirstOccurrence', 0, () => {
      expect(parseTagInput('a,b,a,c,b').join('|')).assertEqual('a|b|c');
    });

    it('comparesTagNameListsInOrder', 0, () => {
      expect(sameTagNames(['a', 'b'], ['a', 'b'])).assertTrue();
      expect(sameTagNames(['a', 'b'], ['b', 'a'])).assertFalse();
      expect(sameTagNames(['a'], ['a', 'b'])).assertFalse();
      expect(sameTagNames([], [])).assertTrue();
    });
  });
}
