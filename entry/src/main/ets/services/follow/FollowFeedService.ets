import { ChallengeState, JsonNetworkClient, NetworkFailureKind, NetworkResult } from '../network/NetworkTypes';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';

/**
 * 「关注的人」动态流。
 *
 * 上游事实(核过 discourse-follow 插件源码,计划文档里写的 `/topics/watched/first`、
 * `/latest?filtered=watched_first` 都不存在 —— core 的 routes.rb 里没有它们):
 *  · 端点:`GET /follow/posts/{username}`,可选 `created_before=<ISO 时间>` 翻页,
 *    可选 `limit`(默认 20)。
 *  · 响应:`{ posts: [...], has_more: bool }`;每条是**帖子**(不是主题),
 *    字段来自 FollowPostSerializer:category_id / created_at / id / post_number / post_type /
 *    topic_id / url / excerpt,外加 `user`(BasicUser)与 `topic`(BasicTopic)。
 *  · 需要登录(`requires_login only: [:follow, :unfollow, :posts]`),且只能看自己(或 staff)。
 *
 * 因此本模块产出的是「楼层级」条目:点一条应当打开对应主题并定位到那一楼,
 * 与主题列表的 Topic 模型是两种东西,不要混用。
 */

export interface FollowFeedItem {
  postId: number;
  topicId: number;
  postNumber: number;
  title: string;
  slug?: string;
  username: string;
  displayName?: string;
  avatarTemplate?: string;
  excerpt: string;
  createdAt: string;
}

export interface FollowFeedPage {
  items: FollowFeedItem[];
  hasMore: boolean;
}

interface RawFollowPost {
  id?: number;
  topic_id?: number;
  post_number?: number;
  created_at?: string;
  url?: string;
  excerpt?: string;
  user?: RawFollowUser;
  topic?: RawFollowTopic;
}

interface RawFollowUser {
  username?: string;
  name?: string;
  avatar_template?: string;
}

interface RawFollowTopic {
  id?: number;
  title?: string;
  slug?: string;
}

interface RawFollowFeedResponse {
  posts?: RawFollowPost[];
  has_more?: boolean;
}

export class FollowFeedService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  /**
   * 拉一页动态。`createdBefore` 传上一页最后一条的 createdAt 即可续页
   * (服务端按时间倒序,`has_more` 为 false 时到底)。
   */
  async load(username: string, createdBefore?: string): Promise<NetworkResult<FollowFeedPage>> {
    const trimmed: string = username.trim();
    if (trimmed.length === 0) {
      return unexpectedResponse<FollowFeedPage>(0, ChallengeState.NONE, '缺少用户名。',
        '登录后才能查看关注动态', NetworkFailureKind.LOCAL_ABORT);
    }
    let path: string = `/follow/posts/${encodeURIComponent(trimmed)}`;
    if (createdBefore !== undefined && createdBefore.length > 0) {
      path += `?created_before=${encodeURIComponent(createdBefore)}`;
    }
    const response: NetworkResult<string> = await this.bridge.getJson(path);
    if (!response.success) {
      return forwardFailure<FollowFeedPage>(response);
    }
    if (response.data === undefined) {
      return unexpectedResponse<FollowFeedPage>(response.statusCode, response.challengeState, '关注动态响应为空。');
    }
    try {
      const payload: RawFollowFeedResponse = JSON.parse(response.data) as RawFollowFeedResponse;
      const posts: RawFollowPost[] = Array.isArray(payload.posts) ? payload.posts : [];
      const items: FollowFeedItem[] = [];
      for (let index: number = 0; index < posts.length; index++) {
        const post: RawFollowPost = posts[index];
        // 没有楼号/主题的条目点了无处可去,直接丢(服务端理论上不会给,但别让坏数据变成死行)。
        if (typeof post.id !== 'number' || typeof post.post_number !== 'number' ||
          typeof post.topic_id !== 'number' || post.post_number <= 0 || post.topic_id <= 0) {
          continue;
        }
        const topic: RawFollowTopic = post.topic ? post.topic : {};
        const user: RawFollowUser = post.user ? post.user : {};
        items.push({
          postId: post.id,
          topicId: post.topic_id,
          postNumber: post.post_number,
          title: typeof topic.title === 'string' ? topic.title : '',
          slug: typeof topic.slug === 'string' && topic.slug.length > 0 ? topic.slug : undefined,
          username: typeof user.username === 'string' ? user.username : '',
          displayName: typeof user.name === 'string' && user.name.length > 0 ? user.name : undefined,
          avatarTemplate: typeof user.avatar_template === 'string' && user.avatar_template.length > 0
            ? user.avatar_template : undefined,
          excerpt: typeof post.excerpt === 'string' ? post.excerpt : '',
          createdAt: typeof post.created_at === 'string' ? post.created_at : ''
        });
      }
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: { items: items, hasMore: payload.has_more === true }
      };
    } catch (error) {
      return unexpectedResponse<FollowFeedPage>(response.statusCode, response.challengeState,
        '关注动态响应不是有效 JSON。');
    }
  }
}
