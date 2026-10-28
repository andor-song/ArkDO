import { describe, it, expect } from '@ohos/hypium';
import { NotificationItem } from '../main/ets/models/Notification';
import {
  NotificationTarget, NotificationTargetKind, chatChannelIdFromUrl, resolveNotificationTarget
} from '../main/ets/services/notification/NotificationRouting';

function baseItem(id: number, type: number): NotificationItem {
  return {
    id: id, type: type, read: false, createdAt: '2026-10-28T00:00:00.000Z',
    actorName: '张三', actorUsername: 'zhangsan', actionText: '回复了你', title: '鸿蒙应用分享',
    iconId: 'reply', iconColor: '#2563EB'
  };
}

export default function notificationRoutingTest() {
  describe('notificationRoutingTest', () => {
    // /chat/c/{slug}/{channelId}[/messageId]:slug 可能是 '-'、编码后的标题,都只取第二段数字。
    it('readsChannelIdFromChatUrl', 0, () => {
      expect(chatChannelIdFromUrl('/chat/c/-/25/565')).assertEqual(25);
      expect(chatChannelIdFromUrl('https://linux.do/chat/c/%E6%97%A5%E5%B8%B8/123')).assertEqual(123);
      expect(chatChannelIdFromUrl('/chat/c/slug/7')).assertEqual(7);
    });

    it('returnsZeroWhenNotAChannelUrl', 0, () => {
      expect(chatChannelIdFromUrl(undefined)).assertEqual(0);
      expect(chatChannelIdFromUrl('')).assertEqual(0);
      expect(chatChannelIdFromUrl('/t/topic/42/7')).assertEqual(0);
      expect(chatChannelIdFromUrl('/chat/c/')).assertEqual(0);
      expect(chatChannelIdFromUrl('/chat/c/slug/not-a-number')).assertEqual(0);
    });

    // 聊天通知常常同时带 topic_id(每条消息背后那句占位主题)。按频道优先,
    // 否则会被当普通帖子打开——里面既没内容也读不出上下文。
    it('prefersChannelOverTopic', 0, () => {
      const item: NotificationItem = baseItem(1, 30);
      item.chatChannelId = 25;
      item.topicId = 999;
      item.postNumber = 3;
      const target: NotificationTarget = resolveNotificationTarget(item);
      expect(target.kind).assertEqual(NotificationTargetKind.CHAT);
      expect(target.channelId).assertEqual(25);
    });

    // data 里没给频道 id 时,仍能从 url 认出来(上游不同版本给的是不同字段)。
    it('fallsBackToUrlForChannel', 0, () => {
      const item: NotificationItem = baseItem(2, 29);
      item.url = '/chat/c/-/88/404';
      expect(resolveNotificationTarget(item).channelId).assertEqual(88);
      expect(resolveNotificationTarget(item).kind).assertEqual(NotificationTargetKind.CHAT);
    });

    it('opensTopicWithPostNumberWhenNoChannel', 0, () => {
      const item: NotificationItem = baseItem(3, 2);
      item.topicId = 1234;
      item.postNumber = 12;
      const target: NotificationTarget = resolveNotificationTarget(item);
      expect(target.kind).assertEqual(NotificationTargetKind.TOPIC);
      expect(target.topicId).assertEqual(1234);
      expect(target.postNumber).assertEqual(12);
    });

    // 私信(6)若拿不到频道 id 就按帖子打开:PM 本身就是一条 topic,详情页能正常显示。
    it('routesPlainPrivateMessageToTopic', 0, () => {
      const item: NotificationItem = baseItem(4, 6);
      item.topicId = 555;
      item.url = '/t/-/555/2';
      expect(resolveNotificationTarget(item).kind).assertEqual(NotificationTargetKind.TOPIC);
    });

    // 「有人关注了你」(discourse-follow 800)没有帖子,以前点了完全没反应 → 改跳发起人主页。
    it('routesFollowingNotificationToActorProfile', 0, () => {
      const item: NotificationItem = baseItem(5, 800);
      const target: NotificationTarget = resolveNotificationTarget(item);
      expect(target.kind).assertEqual(NotificationTargetKind.USER);
      expect(target.username).assertEqual('zhangsan');
    });

    // 801/802 也属关注类,但它们带帖子 → 仍然优先开帖,不能一律跳主页。
    it('keepsTopicForFollowingReplied', 0, () => {
      const item: NotificationItem = baseItem(6, 802);
      item.topicId = 777;
      expect(resolveNotificationTarget(item).kind).assertEqual(NotificationTargetKind.TOPIC);
    });

    it('reportsNoneForSystemNotificationWithoutTarget', 0, () => {
      const item: NotificationItem = baseItem(7, 12);
      item.actorUsername = '';   // 徽章这类系统通知没有发起人
      expect(resolveNotificationTarget(item).kind).assertEqual(NotificationTargetKind.NONE);
    });

    // topicId 为 0 不算数:上游偶尔给 0 占位,拿它开详情页只会是一屏加载失败。
    it('ignoresZeroTopicId', 0, () => {
      const item: NotificationItem = baseItem(8, 1);
      item.topicId = 0;
      expect(resolveNotificationTarget(item).kind).assertEqual(NotificationTargetKind.NONE);
    });
  });
}
