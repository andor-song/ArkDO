import { ChallengeState, JsonNetworkClient, NetworkFailureKind, NetworkResult } from '../network/NetworkTypes';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';

/**
 * 用户卡片:点头像弹的小浮层。
 *
 * 数据源是 `GET /u/{username}/card.json`(Discourse 的 UserCardSerializer),不是 /summary.json:
 * 卡片要的简介、统计与「能不能关注 / 已关注没有」都在 card 里;而且 discourse-follow 插件的
 * `can_follow` / `is_followed` 只加在 user_card 序列化器上,summary 里没有。
 *
 * 关注 / 取关走插件引擎路由:`PUT /follow/{username}`、`DELETE /follow/{username}`
 * (config/routes.rb: mount Follow::Engine, at: "follow"; put/delete ":username")。
 */

export interface UserCard {
  username: string;
  name?: string;
  avatarTemplate?: string;
  bioExcerpt: string;
  postCount: number;
  topicCount: number;
  likesReceived: number;
  totalFollowers: number;
  totalFollowing: number;
  canFollow: boolean;
  isFollowed: boolean;
  canSendPrivateMessage: boolean;
}

interface RawUserCardUser {
  username?: string;
  name?: string;
  avatar_template?: string;
}

interface RawUserCard {
  user?: RawUserCardUser;
  bio_excerpt?: string;
  post_count?: number;
  topic_count?: number;
  likes_received?: number;
  total_followers?: number;
  total_following?: number;
  can_follow?: boolean;
  is_followed?: boolean;
  can_send_private_message_to_user?: boolean;
}

export class UserCardService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  async load(username: string): Promise<NetworkResult<UserCard>> {
    const trimmed: string = username.trim();
    if (trimmed.length === 0) {
      return unexpectedResponse<UserCard>(0, ChallengeState.NONE, '缺少用户名。',
        '没有可展示的用户', NetworkFailureKind.LOCAL_ABORT);
    }
    const response: NetworkResult<string> =
      await this.bridge.getJson(`/u/${encodeURIComponent(trimmed)}/card.json`);
    if (!response.success) {
      return forwardFailure<UserCard>(response);
    }
    if (response.data === undefined) {
      return unexpectedResponse<UserCard>(response.statusCode, response.challengeState, '用户卡片响应为空。');
    }
    try {
      const payload: RawUserCard = JSON.parse(response.data) as RawUserCard;
      const user: RawUserCardUser = payload.user ? payload.user : {};
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: {
          username: typeof user.username === 'string' && user.username.length > 0 ? user.username : trimmed,
          name: typeof user.name === 'string' && user.name.length > 0 ? user.name : undefined,
          avatarTemplate: typeof user.avatar_template === 'string' && user.avatar_template.length > 0
            ? user.avatar_template : undefined,
          bioExcerpt: typeof payload.bio_excerpt === 'string' ? payload.bio_excerpt.trim() : '',
          postCount: typeof payload.post_count === 'number' ? payload.post_count : 0,
          topicCount: typeof payload.topic_count === 'number' ? payload.topic_count : 0,
          likesReceived: typeof payload.likes_received === 'number' ? payload.likes_received : 0,
          totalFollowers: typeof payload.total_followers === 'number' ? payload.total_followers : 0,
          totalFollowing: typeof payload.total_following === 'number' ? payload.total_following : 0,
          canFollow: payload.can_follow === true,
          isFollowed: payload.is_followed === true,
          canSendPrivateMessage: payload.can_send_private_message_to_user === true
        }
      };
    } catch (error) {
      return unexpectedResponse<UserCard>(response.statusCode, response.challengeState,
        '用户卡片响应不是有效 JSON。');
    }
  }

  // 关注 / 取关。插件路由不带 .json,响应 {success:"OK"} 不消费。
  async setFollow(username: string, follow: boolean): Promise<NetworkResult<boolean>> {
    const trimmed: string = username.trim();
    if (trimmed.length === 0) {
      return unexpectedResponse<boolean>(0, ChallengeState.NONE, '缺少用户名。',
        '没有可关注的用户', NetworkFailureKind.LOCAL_ABORT);
    }
    const path: string = `/follow/${encodeURIComponent(trimmed)}`;
    const response: NetworkResult<string> = follow
      ? await this.bridge.putJson(path)
      : await this.bridge.deleteForm(path, '');
    if (!response.success) {
      return forwardFailure<boolean>(response);
    }
    return {
      success: true,
      statusCode: response.statusCode,
      challengeState: response.challengeState,
      data: true
    };
  }
}
