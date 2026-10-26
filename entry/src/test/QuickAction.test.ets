import { describe, it, expect } from '@ohos/hypium';
import {
  QUICK_ACTION_COMPOSE,
  QUICK_ACTION_MAX_AGE_MS,
  QUICK_ACTION_NOTIFICATIONS,
  QUICK_ACTION_SEARCH,
  QUICK_ACTION_WANT_KEY,
  parseQuickAction,
  quickActionOfToken,
  stampQuickAction
} from '../main/ets/services/quickaction/QuickAction';

// 快捷入口的取值写错不会报错,只会"点了图标没反应"。这套断言同时是**配置侧的契约**:
// 下面每个字面量都必须与 resources/base/profile/shortcuts_config.json 里的
// wants[].parameters 逐字一致 —— 改一处不改另一处,快捷入口就静默失效。
export default function quickActionTest() {
  describe('quickActionTest', () => {
    it('parsesKnownActionsFromWantParameters', 0, () => {
      const record: Record<string, string> = {};
      record[QUICK_ACTION_WANT_KEY] = QUICK_ACTION_COMPOSE;
      expect(parseQuickAction(record)).assertEqual(QUICK_ACTION_COMPOSE);
    });

    it('rejectsUnknownAndMissingActions', 0, () => {
      expect(parseQuickAction(undefined)).assertEqual('');
      const emptyRecord: Record<string, string> = {};
      expect(parseQuickAction(emptyRecord)).assertEqual('');
      const bogus: Record<string, string> = {};
      bogus[QUICK_ACTION_WANT_KEY] = 'delete-account';
      expect(parseQuickAction(bogus)).assertEqual('');
    });

    // parameters 的值类型是 Object 而非 string:非字符串要挡掉,不能靠隐式转换蒙混过去
    // (蒙混会把某个数字当成动作码去执行)。
    it('ignoresNonStringParameterValues', 0, () => {
      const numeric: Record<string, Object> = {};
      numeric[QUICK_ACTION_WANT_KEY] = 3;
      expect(parseQuickAction(numeric)).assertEqual('');
    });

    it('trimsSurroundingWhitespace', 0, () => {
      const padded: Record<string, string> = {};
      padded[QUICK_ACTION_WANT_KEY] = '  search  ';
      expect(parseQuickAction(padded)).assertEqual(QUICK_ACTION_SEARCH);
    });

    it('acceptsFreshTokenAndDropsStaleOne', 0, () => {
      const now: number = 1700000000000;
      expect(quickActionOfToken(stampQuickAction(QUICK_ACTION_COMPOSE, now - 5000), now))
        .assertEqual(QUICK_ACTION_COMPOSE);
      expect(quickActionOfToken(stampQuickAction(QUICK_ACTION_COMPOSE, now - QUICK_ACTION_MAX_AGE_MS - 1), now))
        .assertEqual('');
    });

    // 没有分隔符 = 不是本版本写的令牌(例如上一版直接写了个动作码)。什么都不做。
    it('rejectsUnstampedOrUnparsableTokens', 0, () => {
      const now: number = 1700000000000;
      expect(quickActionOfToken(QUICK_ACTION_COMPOSE, now)).assertEqual('');
      expect(quickActionOfToken('compose|昨天', now)).assertEqual('');
      expect(quickActionOfToken('compose|', now)).assertEqual('');
      expect(quickActionOfToken(undefined, now)).assertEqual('');
      expect(quickActionOfToken('', now)).assertEqual('');
    });

    // 未知动作即使带正常时间戳也不能执行(白名单只有一处,两条路径共用)。
    it('rejectsUnknownActionInToken', 0, () => {
      const now: number = 1700000000000;
      expect(quickActionOfToken(stampQuickAction('wipe', now), now)).assertEqual('');
    });

    // 时间戳不可解析(NaN)按陈旧处理:宁可不执行,也不要拿来路不明的令牌去跳转。
    it('dropsTokenWithUnparsableTimestamp', 0, () => {
      expect(quickActionOfToken('search|abc', 1700000000000)).assertEqual('');
    });
  });
}
