import { describe, it, expect } from '@ohos/hypium';
import {
  NOTIFICATION_LEVEL_MUTED,
  NOTIFICATION_LEVEL_REGULAR,
  NOTIFICATION_LEVEL_TRACKING,
  NOTIFICATION_LEVEL_WATCHING,
  TOPIC_NOTIFICATION_OPTIONS,
  buildNotificationLevelBody,
  describeNotificationLevel,
  isKnownNotificationLevel,
  normalizeNotificationLevel,
  notificationLevelPath
} from '../main/ets/services/topic/TopicNotificationLevels';

// 档位是服务端定义的整数,写错不会报错、只会静默变成"通知收不到/收不停"。
// 这层纯逻辑是客户端唯一能挡住越界值的地方(服务端只做 .to_i,不校验范围)。
export default function topicNotificationLevelsTest() {
  describe('topicNotificationLevelsTest', () => {
    it('levelsMatchUpstreamTopicLevels', 0, () => {
      expect(NOTIFICATION_LEVEL_MUTED).assertEqual(0);
      expect(NOTIFICATION_LEVEL_REGULAR).assertEqual(1);
      expect(NOTIFICATION_LEVEL_TRACKING).assertEqual(2);
      expect(NOTIFICATION_LEVEL_WATCHING).assertEqual(3);
      expect(TOPIC_NOTIFICATION_OPTIONS.length).assertEqual(4);
    });

    it('buildsBodyOnlyForKnownLevels', 0, () => {
      expect(buildNotificationLevelBody(NOTIFICATION_LEVEL_WATCHING)).assertEqual('notification_level=3');
      expect(buildNotificationLevelBody(NOTIFICATION_LEVEL_MUTED)).assertEqual('notification_level=0');
      // 越界/小数一律拒发:服务端不校验,脏值会直接落库。
      expect(buildNotificationLevelBody(7)).assertEqual('');
      expect(buildNotificationLevelBody(-1)).assertEqual('');
      expect(buildNotificationLevelBody(1.5)).assertEqual('');
    });

    // 上游对「从没设过的人」也回 regular(1),所以「未知」与「正常」在数据上无法区分;
    // 但字段整个缺失(旧站点/插件裁剪)时必须能被识别出来 —— 顶栏据此决定挂不挂铃铛。
    it('treatsMissingFieldAsUnknownNotRegular', 0, () => {
      expect(isKnownNotificationLevel(undefined)).assertFalse();
      expect(isKnownNotificationLevel(NOTIFICATION_LEVEL_REGULAR)).assertTrue();
      // 显示回落成「正常」,但这个回落不等于"服务端给了值"。
      expect(normalizeNotificationLevel(undefined)).assertEqual(NOTIFICATION_LEVEL_REGULAR);
      expect(describeNotificationLevel(undefined)).assertEqual('正常');
      expect(describeNotificationLevel(NOTIFICATION_LEVEL_MUTED)).assertEqual('静默');
    });

    it('pathMatchesUpstreamRoute', 0, () => {
      expect(notificationLevelPath(12345)).assertEqual('/t/12345/notifications');
    });
  });
}
