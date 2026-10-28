import { ChallengeState, JsonNetworkClient, NetworkFailureKind, NetworkResult } from '../network/NetworkTypes';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';

/**
 * 版块 / 标签的通知档位(静音 / 正常)。
 *
 * 上游事实(核过 Discourse 源码,别照「PUT /category_mutes」那种印象改 —— 那条路由在 core 里根本不存在):
 *  · 版块:POST /category/{id}/notifications,form 参数 `notification_level`
 *    (app/controllers/categories_controller.rb#set_notifications)。
 *  · 标签:PUT /tag/{name}/notifications.json,form 参数 `tag_notification[notification_level]`
 *    (tags_controller.rb#update_notifications)。该路由在 `constraints format: :json` 的 scope 里,
 *    **`.json` 不能省**,否则匹配不到。
 *  · 当前静音态:GET /u/{username}.json 的 user.muted_category_ids / user.muted_tags
 *    (user_serializer.rb 的两个 attribute)。
 *
 * 档位编号沿用全站同一套:0 静音 / 1 正常(与 TopicNotificationLevels 的 0..4 同源)。
 */

const LEVEL_MUTED: number = 0;
const LEVEL_REGULAR: number = 1;

export interface MutePrefs {
  categoryIds: number[];
  tags: string[];
}

// GET /u/{username}.json 只取用到的两个字段。Discourse 一律把用户包在 user 里。
interface RawUserPrefsResponse {
  user?: RawUserPrefs;
}

interface RawUserPrefs {
  muted_category_ids?: number[];
  muted_tags?: string[];
}

export class MuteService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  // 当前用户已静音的版块 id 与标签名。未登录/用户名为空时本地拒发。
  async loadPrefs(username: string): Promise<NetworkResult<MutePrefs>> {
    const trimmed: string = username.trim();
    if (trimmed.length === 0) {
      return unexpectedResponse<MutePrefs>(0, ChallengeState.NONE, '缺少用户名。',
        '登录后才能查看静音设置', NetworkFailureKind.LOCAL_ABORT);
    }
    const response: NetworkResult<string> =
      await this.bridge.getJson(`/u/${encodeURIComponent(trimmed)}.json`);
    if (!response.success) {
      return forwardFailure<MutePrefs>(response);
    }
    if (response.data === undefined) {
      return unexpectedResponse<MutePrefs>(response.statusCode, response.challengeState, '站点用户信息响应为空。');
    }
    try {
      const payload: RawUserPrefsResponse = JSON.parse(response.data) as RawUserPrefsResponse;
      const user: RawUserPrefs = payload.user ? payload.user : {};
      const categoryIds: number[] = [];
      const rawIds: number[] = Array.isArray(user.muted_category_ids) ? user.muted_category_ids : [];
      for (let index: number = 0; index < rawIds.length; index++) {
        if (typeof rawIds[index] === 'number' && rawIds[index] > 0) {
          categoryIds.push(rawIds[index]);
        }
      }
      const tags: string[] = [];
      const rawTags: string[] = Array.isArray(user.muted_tags) ? user.muted_tags : [];
      for (let index: number = 0; index < rawTags.length; index++) {
        if (typeof rawTags[index] === 'string' && rawTags[index].length > 0) {
          tags.push(rawTags[index]);
        }
      }
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: { categoryIds: categoryIds, tags: tags }
      };
    } catch (error) {
      return unexpectedResponse<MutePrefs>(response.statusCode, response.challengeState,
        '站点用户信息响应不是有效 JSON。');
    }
  }

  // 静音 / 恢复正常 一个版块。返回 true 表示服务端已接受(响应体不消费:上层只需翻转本地开关)。
  async setCategoryMuted(categoryId: number, muted: boolean): Promise<NetworkResult<boolean>> {
    if (categoryId <= 0) {
      return unexpectedResponse<boolean>(0, ChallengeState.NONE, '版块 id 非法。',
        '没有可设置的版块', NetworkFailureKind.LOCAL_ABORT);
    }
    const body: string = `notification_level=${muted ? LEVEL_MUTED : LEVEL_REGULAR}`;
    const response: NetworkResult<string> =
      await this.bridge.postForm(`/category/${categoryId}/notifications`, body);
    return this.asBooleanResult(response);
  }

  // 静音 / 恢复正常 一个标签(按名字,中文标签名会被编码)。
  async setTagMuted(tagName: string, muted: boolean): Promise<NetworkResult<boolean>> {
    const trimmed: string = tagName.trim();
    if (trimmed.length === 0) {
      return unexpectedResponse<boolean>(0, ChallengeState.NONE, '标签名为空。',
        '请输入标签名', NetworkFailureKind.LOCAL_ABORT);
    }
    // 括号是表单数组/嵌套参数的写法,必须预编码;直接写 `tag_notification[notification_level]`
    // 会被桥当成 URL 里的方括号(Rails 侧收不到嵌套结构)。
    const body: string = `tag_notification%5Bnotification_level%5D=${muted ? LEVEL_MUTED : LEVEL_REGULAR}`;
    const response: NetworkResult<string> =
      await this.bridge.putForm(`/tag/${encodeURIComponent(trimmed)}/notifications.json`, body);
    return this.asBooleanResult(response);
  }

  private asBooleanResult(response: NetworkResult<string>): NetworkResult<boolean> {
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
