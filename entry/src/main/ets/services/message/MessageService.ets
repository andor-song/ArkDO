import { MessageInboxPage, MessageThread } from '../../models/Message';
import { User } from '../../models/User';
import { ChallengeState, JsonNetworkClient, NetworkResult } from '../network/NetworkTypes';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';
import { HtmlText } from '../content/HtmlText';

// 私信收件箱服务:/u/{username}/messages.json(当前登录用户的私信会话列表)。
//
// Discourse 该端点有两种历史形态的响应,这里都接:
//   - 新版:user_message_topics[] + users[](会话顶层携带参与者/最后回复/未读);
//   - 旧版:topic_list.topics[](标准主题列表壳)。
// 元素里 participants/posters 是 {user_id,username,name,avatar_template} 的精简对象,
// 没有 flair,直接按字段拼 User 即可。几种版本字段名略有出入,统一按可选字段防御解析。
const LOG_TAG: string = '[ArkDO][Message]';
// 服务端固定每页条数(私信收件箱 50/页):满页即视为还有下一页,与列表接口判定一致。
const MESSAGE_PAGE_SIZE: number = 50;

// 单个会话(discourse 主题精简对象)。字段全体可选、防御解析。
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
  // participants 在新版响应顶层;posters 是旧版 topic_list 壳里的发帖人引用。
  participants?: DiscourseMessageUserRef[];
  posters?: DiscourseMessageUserRef[];
}

// 参与者/发帖人精简对象。
interface DiscourseMessageUserRef {
  user_id?: number;
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
}

// 顶层 users 字典(把 user_id 引到具体头像/名字)。
interface DiscourseUserBrief {
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
}

interface DiscourseMessageTopicList {
  topics?: DiscourseMessageTopic[];
}

interface DiscourseMessageResponse {
  user_message_topics?: DiscourseMessageTopic[];
  topic_list?: DiscourseMessageTopicList;
  users?: DiscourseUserBrief[];
  total?: number;
}

export class MessageService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  // 收件箱一页。page 从 1 起(?page=N);hasMore 按「本页满 50 条」兜底判定
  // (个别站点有 total 字段则优先按 total 判)。
  async getInbox(username: string, page: number): Promise<NetworkResult<MessageInboxPage>> {
    const path: string = `/u/${encodeURIComponent(username)}/messages.json?page=${page}`;
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
        // 最终标题:服务端 fancy_title 优先;空组名兜底用「群聊」;两者都没有就退回「私信」。
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
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: {
          threads: threads,
          hasMore: threads.length < total || raw.length >= MESSAGE_PAGE_SIZE
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
  // participants 是数组对象,和 posters 都带 user_id/id;顶层 users 词典里没有的按原字段拼。
  private resolveParticipants(item: DiscourseMessageTopic, userDict: Map<number, DiscourseUserBrief>): User[] {
    const refs: DiscourseMessageUserRef[] = (item.participants ?? item.posters ?? []);
    const result: User[] = [];
    for (let index: number = 0; index < refs.length; index++) {
      const ref: DiscourseMessageUserRef = refs[index];
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
