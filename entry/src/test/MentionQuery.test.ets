import { describe, it, expect } from '@ohos/hypium';
import {
  MentionContext, MentionReplaceResult, mentionQueryAt, replaceMention
} from '../main/ets/services/topic/MentionQuery';

export default function mentionQueryTest() {
  describe('mentionQueryTest', () => {
    it('detectsMentionBeforeCaret', 0, () => {
      const context: MentionContext | undefined = mentionQueryAt('你好 @ali', 7);
      expect(context?.term).assertEqual('ali');
      expect(context?.start).assertEqual(3);
      // 刚打出 @ 也要联想(这正是想看候选的时刻)。
      expect(mentionQueryAt('@', 1)?.term).assertEqual('');
      expect(mentionQueryAt('hi\n@bob', 7)?.term).assertEqual('bob');
    });

    // 邮箱与路径里的 @ 不算提及;打了空格就认为这次提及已结束。
    it('ignoresEmailsAndFinishedMentions', 0, () => {
      expect(mentionQueryAt('foo@bar', 7) === undefined).assertTrue();
      expect(mentionQueryAt('@alice 你好', 9) === undefined).assertTrue();
      expect(mentionQueryAt('没有 at', 7) === undefined).assertTrue();
    });

    it('replacesWholeTokenAndPlacesCaretAfterSpace', 0, () => {
      const context: MentionContext = mentionQueryAt('你好 @ali', 7)!;
      const result: MentionReplaceResult = replaceMention('你好 @ali', context, 'alice', 7);
      expect(result.text).assertEqual('你好 @alice ');
      expect(result.caret).assertEqual(10);
    });

    it('doesNotDoubleSpace', 0, () => {
      const context: MentionContext = mentionQueryAt('@ali 继续', 4)!;
      const result: MentionReplaceResult = replaceMention('@ali 继续', context, 'alice', 4);
      expect(result.text).assertEqual('@alice 继续');
      // 原文已有空格:不重复补,光标落在那个空格之前。
      expect(result.caret).assertEqual(6);
    });

    it('keepsTextWhenUsernameEmpty', 0, () => {
      const context: MentionContext = mentionQueryAt('@a', 2)!;
      expect(replaceMention('@a', context, '   ', 2).text).assertEqual('@a');
    });
  });
}
