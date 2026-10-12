import { MessageInboxPage, MessageThread } from '../../models/Message';
import { User } from '../../models/User';
import { AppConstants } from '../../common/constants/AppConstants';
import { ChallengeState, JsonNetworkClient, NetworkResult } from '../network/NetworkTypes';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';
import { HtmlText } from '../content/HtmlText';

// 私信收件箱服务。
//
// 数据源按站点能力自适应,先试 Chat 再落 PM:
//   - Chat 源:GET /chat/api/me/channels。linux.do 等启用 Discourse Chat 的站点,
//     私信会话实际存放在 chat 直聊频道(direct_message_channels[])里,传统私信主题收件箱
//     往往是空的。响应结构:
//       {
//         public_channels: [...],            // 公开频道,忽略
//         direct_message_channels: [{
//           id, title, unicode_title, slug, status, ...
//           chatable: { group, users: [{id,username,name,avatar_template,...}] },
//           last_message: { id, message, excerpt, created_at, ... },
//           current_user_membership: { last_read_message_id, ... },   // 有未读才带
//           meta: {...}
//         }],
//         tracking: { channel_tracking: { [id]: { mention_count, unread_count, ... } }, ... },
//         ...
//       }
//   - PM 源:GET /topics/private-messages/{username}.json → topic_list.topics[],
//     兼容 user_message_topics[] 旧形态。
// 打开聊天页走 /chat/c/{title}/{id}(通用 WebViewPage);PM 会话走原生主题详情页。
const LOG_TAG: string = '[ArkDO][Message]';

// 单个 PM 会话(可 null)。旧版 topic_list 壳里的发帖人引用字段。
interface DiscourseMessageTopic {
  id?: number;
  topic_id?: number;
  title?: string;
  fancy_title?: string;
  slug?: string;
  group_name?: string;
  last_posted_at?: string;
  bumped_at?: string;
  created_at?: string;
  posts_count?: number;
  highest_post_number?: number;
  last_read_post_number?: number;
  unseen?: boolean;
  excerpt?: string;
  participants?: DiscourseUserRef[];
  posters?: DiscourseUserRef[];
}

interface DiscourseUserRef {
  user_id?: number;
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
}

interface DiscourseUserBrief {
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
}

interface DiscourseMessageTopicList {
  topics?: DiscourseMessageTopic[];
  more_topics_url?: string;
}

interface DiscourseMessageResponse {
  user_message_topics?: DiscourseMessageTopic[];
  topic_list?: DiscourseMessageTopicList;
  users?: DiscourseUserBrief[];
  total?: number;
}

// ==================== Chat 源响应 ====================

interface ChatUser {
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
}

interface ChatDirectMessageChatable {
  group?: boolean;
  users?: ChatUser[];
}

interface ChatLastMessage {
  id?: number;
  message?: string;
  excerpt?: string;
  created_at?: string;
}

interface ChatMembership {
  last_read_message_id?: number;
}

interface ChatChannel {
  id?: number;
  title?: string;
  unicode_title?: string;
  slug?: string;
  chatable?: ChatDirectMessageChatable;
  last_message?: ChatLastMessage;
  current_user_membership?: ChatMembership;
}

interface ChatChannelTracking {
  mention_count?: number;
  unread_count?: number;
}

interface ChatTrackingState {
  channel_tracking?: Record<string, ChatChannelTracking>;
}

interface ChatMeChannelsResponse {
  direct_message_channels?: ChatChannel[];
  tracking?: ChatTrackingState;
}


export class MessageService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  // 私信列表一页。page 从 1 起。优先 Chat 源;Chat 请求失败或无直聊频道时回退传统 PM。
  async getInbox(username: string, page: number): Promise<NetworkResult<MessageInboxPage>> {
    const chatTry: NetworkResult<MessageInboxPage> = await this.tryChatInbox();
    if (chatTry.success && chatTry.data !== undefined && chatTry.data.threads.length > 0) {
      return chatTry;
    }
    // Chat 没有会话(可能是未启用 chat 的站点,或真的一条都没有):
    // 落到传统 PM 收件箱兜底。首页走 PM,更多页继续走 PM。
    return this.getPmInbox(username, page);
  }

  // Chat 直聊频道列表 → 会话行。失败(未启用 chat/无权限/结构变化)返回失败,由外层回落。
  private async tryChatInbox(): Promise<NetworkResult<MessageInboxPage>> {
    const path: string = '/chat/api/me/channels';
    const response: NetworkResult<string> = await this.bridge.getJson(path);
    if (!response.success) {
      return forwardFailure<MessageInboxPage>(response);
    }
    if (response.data === undefined || response.data.length === 0) {
      return unexpectedResponse<MessageInboxPage>(response.statusCode, response.challengeState,
        '站点聊天响应为空。');
    }

    try {
      const payload: ChatMeChannelsResponse = JSON.parse(response.data) as ChatMeChannelsResponse;
      const channels: ChatChannel[] = payload.direct_message_channels ?? [];
      const threads: MessageThread[] = [];
      for (let index: number = 0; index < channels.length; index++) {
        const channel: ChatChannel = channels[index];
        const channelId: number | undefined = typeof channel.id === 'number' ? channel.id : undefined;
        if (channelId === undefined) {
          continue;
        }
        // 标题:频道 title(群聊为群名,单聊为对方用户名),空则退回「私信」。
        const rawTitle: string = channel.title && channel.title.length > 0
          ? channel.title : (channel.unicode_title && channel.unicode_title.length > 0
            ? channel.unicode_title : '');
        const displayTitle: string = rawTitle.length > 0 ? HtmlText.decodeEntities(rawTitle) : '私信';
        // 参与者:直聊对象(自己除外)。
        const chatables: ChatUser[] = channel.chatable?.users ?? [];
        const participants: User[] = [];
        for (let uidx: number = 0; uidx < chatables.length; uidx++) {
          const cu: ChatUser = chatables[uidx];
          if (typeof cu.id !== 'number') {
            continue;
          }
          const u: User = {
            id: cu.id,
            username: cu.username && cu.username.length > 0 ? cu.username : ''
          };
          if (cu.name && cu.name.length > 0) {
            u.displayName = cu.name;
          }
          const avatar: string | undefined = cu.avatar_template;
          if (avatar && avatar.length > 0) {
            u.avatarTemplate = avatar;
          }
          participants.push(u);
        }
        // 未读:membership.last_read_message_id < last_message.id,或 tracking 里 unread_count>0。
        const lastMessageId: number | undefined = typeof channel.last_message?.id === 'number'
          ? channel.last_message?.id : undefined;
        const lastRead: number | undefined = typeof channel.current_user_membership?.last_read_message_id === 'number'
          ? channel.current_user_membership?.last_read_message_id : undefined;
        const tracked: ChatChannelTracking | undefined = payload.tracking?.channel_tracking
          ? (payload.tracking?.channel_tracking as Record<string, ChatChannelTracking>)[String(channelId)]
          : undefined;
        const unseen: boolean = (lastMessageId !== undefined && lastRead !== undefined && lastRead < lastMessageId)
          || (typeof tracked?.unread_count === 'number' && tracked.unread_count > 0);
        // 摘要:最后一则消息。
        const excerpt: string = channel.last_message?.excerpt && channel.last_message.excerpt.length > 0
          ? HtmlText.toPlainText(channel.last_message.excerpt)
          : (channel.last_message?.message ? HtmlText.toPlainText(channel.last_message.message) : '');
        threads.push({
          topicId: channelId,
          title: displayTitle,
          participants: participants,
          lastPostedAt: channel.last_message?.created_at,
          unseen: unseen,
          excerpt: excerpt,
          postsCount: 0,
          chatUrl: this.buildChatChannelUrl(channel)
        });
      }
      // Chat 源一次返回全部直聊(无分页),hasMore=false。
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: {
          threads: threads,
          hasMore: false
        }
      };
    } catch (error) {
      return unexpectedResponse<MessageInboxPage>(response.statusCode, response.challengeState,
        '站点聊天响应不是有效 JSON。');
    }
  }

  // 聊天页 WebView 地址:/chat/c/{channel_title}/{channel_id}。
  // 与 Discourse 前端一致:公开频道是 /chat/c/{slug}/{id},直聊频道 title 常为对方用户名。
  private buildChatChannelUrl(channel: ChatChannel): string {
    const title: string = channel.title && channel.title.length > 0
      ? channel.title : (channel.slug && channel.slug.length > 0 ? channel.slug : 'channel');
    const encoded: string = encodeURIComponent(title.replace(/\s+/g, '-'));
    const channelId: number = typeof channel.id === 'number' ? channel.id : 0;
    return `${AppConstants.BASE_URL}/chat/c/${encoded}/${channelId}`;
  }

  // ==================== PM 源(传统私信主题收件箱)====================

  // 收件箱一页。page 从 1 起(?page=N),走 list 控制器私信列表端点。
  // hasMore 优先按响应里 more_topics_url 是否有值判定。
  private async getPmInbox(username: string, page: number): Promise<NetworkResult<MessageInboxPage>> {
    const path: string = `/topics/private-messages/${encodeURIComponent(username)}.json?page=${page}`;
    const response: NetworkResult<string> = await this.bridge.getJson(path);
    if (!response.success) {
      return forwardFailure<MessageInboxPage>(response);
    }
    if (response.data === undefined) {
      return unexpectedResponse<MessageInboxPage>(response.statusCode, response.challengeState,
        '站点收件箱响应为空。');
    }

    try {
      const payload: DiscourseMessageResponse = JSON.parse(response.data) as DiscourseMessageResponse;
      const raw: DiscourseMessageTopic[] = payload.user_message_topics ?? payload.topic_list?.topics ?? [];
      const userDict: Map<number, DiscourseUserBrief> = new Map<number, DiscourseUserBrief>();
      const briefs: DiscourseUserBrief[] = payload.users ?? [];
      for (let index: number = 0; index < briefs.length; index++) {
        const brief: DiscourseUserBrief = briefs[index];
        if (typeof brief.id === 'number') {
          userDict.set(brief.id, brief);
        }
      }

      const threads: MessageThread[] = [];
      for (let index: number = 0; index < raw.length; index++) {
        const item: DiscourseMessageTopic = raw[index];
        const topicId: number | undefined = typeof item.topic_id === 'number'
          ? item.topic_id : (typeof item.id === 'number' ? item.id : undefined);
        const title: string = this.fancyTitleOf(item);
        if (topicId === undefined || title.length === 0) {
          continue;
        }
        const participants: User[] = this.resolveParticipants(item, userDict);
        const displayTitle: string = title.length > 0 ? title
          : (item.group_name && item.group_name.length > 0 ? item.group_name : '私信');
        const unseen: boolean = item.unseen === true
          || (typeof item.last_read_post_number === 'number' && typeof item.highest_post_number === 'number'
            && item.last_read_post_number < item.highest_post_number);
        threads.push({
          topicId: topicId,
          title: displayTitle,
          participants: participants,
          lastPostedAt: item.last_posted_at ?? item.bumped_at ?? item.created_at,
          unseen: unseen,
          excerpt: item.excerpt ? HtmlText.toPlainText(item.excerpt) : '',
          postsCount: typeof item.posts_count === 'number' ? item.posts_count : 0,
          lastReadPostNumber: typeof item.last_read_post_number === 'number'
            ? item.last_read_post_number : undefined,
          slug: item.slug && item.slug.length > 0 ? item.slug : ''
        });
      }

      const total: number = typeof payload.total === 'number' ? payload.total : raw.length;
      const moreUrl: string | undefined = payload.topic_list?.more_topics_url;
      const hasMore: boolean = (typeof moreUrl === 'string' && moreUrl.length > 0)
        || threads.length < total
        || raw.length >= 50;
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: {
          threads: threads,
          hasMore: hasMore
        }
      };
    } catch (error) {
      return unexpectedResponse<MessageInboxPage>(response.statusCode, response.challengeState,
        '站点收件箱响应不是有效 JSON。');
    }
  }

  // 标题:fancy_title 优先、回退 title(个别版本只有 title),统一解码 HTML 实体。
  private fancyTitleOf(item: DiscourseMessageTopic): string {
    const raw: string | undefined = item.fancy_title && item.fancy_title.length > 0
      ? item.fancy_title : item.title;
    if (!raw || raw.length === 0) {
      return '';
    }
    return HtmlText.decodeEntities(raw);
  }

  // 参与者精简对象 → User。源头取 participants,旧版 topic_list 壳没有 participants 时用 posters。
  private resolveParticipants(item: DiscourseMessageTopic, userDict: Map<number, DiscourseUserBrief>): User[] {
    const refs: DiscourseUserRef[] = (item.participants ?? item.posters ?? []);
    const result: User[] = [];
    for (let index: number = 0; index < refs.length; index++) {
      const ref: DiscourseUserRef = refs[index];
      const userId: number | undefined = typeof ref.user_id === 'number'
        ? ref.user_id : (typeof ref.id === 'number' ? ref.id : undefined);
      const brief: DiscourseUserBrief | undefined = userId !== undefined ? userDict.get(userId) : undefined;
      const username: string = ref.username && ref.username.length > 0
        ? ref.username : (brief && brief.username ? brief.username : '');
      if (username.length === 0) {
        continue;
      }
      const user: User = {
        id: userId ?? 0,
        username: username
      };
      const name: string | undefined = ref.name && ref.name.length > 0 ? ref.name
        : (brief && brief.name ? brief.name : undefined);
      if (name && name.length > 0) {
        user.displayName = name;
      }
      const avatar: string | undefined = ref.avatar_template && ref.avatar_template.length > 0
        ? ref.avatar_template : (brief && brief.avatar_template ? brief.avatar_template : undefined);
      if (avatar && avatar.length > 0) {
        user.avatarTemplate = avatar;
      }
      result.push(user);
    }
    return result;
  }
}
