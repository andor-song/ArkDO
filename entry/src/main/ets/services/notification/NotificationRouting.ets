/**
 * 通知行的点击目标判定(纯函数,本地 harness 可跑)。
 *
 * 为什么要抽出来:此前点击一律「有 topicId 就开帖子,没有就什么都不做」,
 * 于是聊天通知被当普通帖子打开、「有人关注了你」(discourse-follow 的 800-802)点了没反应。
 * 分流规则只有这一处,页面按 kind 执行,不再在 UI 里堆 if。
 */
import { NotificationItem } from '../../models/Notification';

export enum NotificationTargetKind {
  CHAT = 'chat',
  TOPIC = 'topic',
  USER = 'user',
  NONE = 'none'
}

export interface NotificationTarget {
  kind: NotificationTargetKind;
  topicId?: number;
  postNumber?: number;
  channelId?: number;
  username?: string;
}

// discourse-follow 插件的三个类型:关注了你 / 发布了新主题 / 回复了主题。
// 后两个带 topic_id,走 TOPIC;只有「关注了你」没有帖子,该跳发起人主页。
const T_FOLLOWING: number = 800;
const T_FOLLOWING_CREATED_TOPIC: number = 801;
const T_FOLLOWING_REPLIED: number = 802;

// 聊天频道的站内地址:/chat/c/{slug}/{channelId}[/messageId]。slug 常被站点写成 '-' 或 URL 编码的标题,
// 两种都要认,所以只锚定「/chat/c/ 之后第一段非斜杠、第二段是数字」。
const CHAT_CHANNEL_URL: RegExp = /\/chat\/c\/[^/]+\/(\d+)/;

// 从通知 url 里取频道 id;取不到返回 0(调用方据此退回开帖)。
export function chatChannelIdFromUrl(url: string | undefined): number {
  if (url === undefined) {
    return 0;
  }
  const match: RegExpMatchArray | null = url.match(CHAT_CHANNEL_URL);
  if (match === null || match.length < 2) {
    return 0;
  }
  const parsed: number = parseInt(match[1], 10);
  return !isNaN(parsed) && parsed > 0 ? parsed : 0;
}

function isFollowingType(type: number): boolean {
  return type === T_FOLLOWING || type === T_FOLLOWING_CREATED_TOPIC || type === T_FOLLOWING_REPLIED;
}

/**
 * 判定优先级:频道 > 帖子 > 发起人 > 什么都不做。
 *
 * 频道排在最前是因为它更具体:聊天通知可能同时带 topic_id(每条聊天消息背后都有一句
 * 占位主题),那种帖子打开是空的、也读不出上下文,而频道 id 直接落到聊天页。
 * 判据用「有没有频道 id」而不是通知类型编号:类型编号(29/30)是 Chat 侧的约定,
 * 而 data.chat_channel_id / url 是这条通知自己给出的证据,站点装了与否都不影响正确性。
 */
export function resolveNotificationTarget(item: NotificationItem): NotificationTarget {
  const fromData: number = item.chatChannelId !== undefined ? item.chatChannelId : 0;
  const channelId: number = fromData > 0 ? fromData : chatChannelIdFromUrl(item.url);
  if (channelId > 0) {
    return { kind: NotificationTargetKind.CHAT, channelId: channelId };
  }
  if (item.topicId !== undefined && item.topicId > 0) {
    return { kind: NotificationTargetKind.TOPIC, topicId: item.topicId, postNumber: item.postNumber };
  }
  if (isFollowingType(item.type) && item.actorUsername.length > 0) {
    return { kind: NotificationTargetKind.USER, username: item.actorUsername };
  }
  return { kind: NotificationTargetKind.NONE };
}
