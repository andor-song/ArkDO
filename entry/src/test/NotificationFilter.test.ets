import { describe, it, expect } from '@ohos/hypium';
import {
  NOTIFICATION_FILTER_ALL, NOTIFICATION_FILTER_OPTIONS, NotificationFilterOption,
  buildNotificationsPath, notificationFilterTypeNames
} from '../main/ets/services/notification/NotificationFilter';

// 「上游用的是类型名,不是本仓的 T_* 常量名」——这条最容易被改坏,所以逐个校验形状:
// 全小写下划线、非空,且绝不出现本仓常量名那种拼写(如 groupMentioned)。
function isUpstreamTypeName(name: string): boolean {
  return /^[a-z][a-z0-9_]*$/.test(name);
}

export default function notificationFilterTest() {
  describe('notificationFilterTest', () => {
    // 不带筛选时必须与改动前的拼串逐字相同:通知页原本就是这个形状,
    // 任何「顺手加的默认参数」都会让服务端行为悄悄变化。
    it('keepsLegacyPathWhenNoFilter', 0, () => {
      expect(buildNotificationsPath(30, 0, false)).assertEqual('/notifications.json?limit=30&offset=0');
      expect(buildNotificationsPath(30, 30, false, [])).assertEqual('/notifications.json?limit=30&offset=30');
      expect(buildNotificationsPath(30, 0, false, undefined)).assertEqual('/notifications.json?limit=30&offset=0');
    });

    // recent 那一对只给首屏:翻页与筛选后的重载不该重复 bump「看过」。
    it('appendsRecentPairOnlyForFirstPage', 0, () => {
      expect(buildNotificationsPath(30, 0, true))
        .assertEqual('/notifications.json?limit=30&offset=0&recent=true&bump_last_seen_reviewable=true');
      expect(buildNotificationsPath(30, 30, false).indexOf('recent') < 0).assertTrue();
    });

    it('appendsFilterByTypesWithUpstreamParamName', 0, () => {
      expect(buildNotificationsPath(30, 0, false, ['replied', 'quoted']))
        .assertEqual('/notifications.json?limit=30&offset=0&filter_by_types=replied,quoted');
      // 参数名是 filter_by_types,不是 filter(上游 notifications_controller.rb)。
      const path: string = buildNotificationsPath(30, 0, true, ['mentioned']);
      expect(path).assertContain('filter_by_types=mentioned');
      expect(path.indexOf('?filter=') < 0).assertTrue();
    });

    it('unknownKeyDegradesToNoParamNotEmptySet', 0, () => {
      // 未知键退成「全部」=不发参数。若退成空数组以外的东西或误发一个空 filter_by_types,
      // 上游会当成「筛选不到任何类型」而返回空列表——看起来像通知全没了。
      expect(notificationFilterTypeNames('no_such_key').length).assertEqual(0);
      expect(buildNotificationsPath(30, 0, false, notificationFilterTypeNames('no_such_key')))
        .assertEqual('/notifications.json?limit=30&offset=0');
    });

    it('everyOptionHasUniqueKeyAndUpstreamNames', 0, () => {
      const seen: string[] = [];
      for (let index: number = 0; index < NOTIFICATION_FILTER_OPTIONS.length; index++) {
        const option: NotificationFilterOption = NOTIFICATION_FILTER_OPTIONS[index];
        expect(seen.indexOf(option.key) < 0).assertTrue();
        seen.push(option.key);
        expect(option.label.length > 0).assertTrue();
        for (let nameIndex: number = 0; nameIndex < option.typeNames.length; nameIndex++) {
          expect(isUpstreamTypeName(option.typeNames[nameIndex])).assertTrue();
        }
      }
      // 「全部」在第一枚且不带类型名,选中态与「不带参数」同一含义。
      expect(NOTIFICATION_FILTER_OPTIONS[0].key).assertEqual(NOTIFICATION_FILTER_ALL);
      expect(NOTIFICATION_FILTER_OPTIONS[0].typeNames.length).assertEqual(0);
    });
  });
}
