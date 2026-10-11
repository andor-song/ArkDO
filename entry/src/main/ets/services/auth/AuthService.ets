import { SidebarTag, User } from '../../models/User';
import { NameCollator } from '../../common/utils/NameCollator';
import { ChallengeState, JsonNetworkClient, NetworkResult } from '../network/NetworkTypes';
import { WebSessionManager } from '../web/WebSessionManager';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';

const CURRENT_SESSION_PATH: string = '/session/current.json';
// 未登录时 /session/current.json 的状态码。Discourse 对匿名请求回 404 + 空 body,
// 而非 200 + current_user:null——它是登出/会话过期的判据,不是错误。
const CURRENT_SESSION_ANONYMOUS_STATUS: number = 404;

interface DiscourseCurrentSessionResponse {
  current_user?: DiscourseCurrentUser | null;
}

interface DiscourseCurrentUser {
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
  animated_avatar?: string;
  unread_notifications?: number;
  unread_high_priority_notifications?: number;
  // 总未读(含私信等高优先级),对应铃铛角标真值(user.rb all_unread_notifications_count:816)。
  // unread_notifications 只数 high_priority=FALSE,会漏掉私信,不能用于角标。
  all_unread_notifications_count?: number;
  draft_count?: number;
  // 侧栏自选的标签与版块。CurrentUserSerializer 里由 UserSidebarMixin 提供:
  // sidebar_tags = 用户 SidebarSectionLink 里 linkable_type='Tag' 的那些,已按话题数倒序、已按可见性过滤;
  // sidebar_category_ids 同理(且已与用户可见版块求过交集)。tagging_enabled 关掉时前者整个不出现。
  sidebar_tags?: DiscourseSidebarTag[];
  sidebar_category_ids?: number[];
  // 信任等级与管理身份。CurrentUserSerializer 里声明为 :trust_level / :admin? / :moderator?,
  // 序列化后的键名是不带问号的 trust_level / admin / moderator。编辑器用它判能否传附件。
  trust_level?: number;
  admin?: boolean;
  moderator?: boolean;
}

// SidebarTagSerializer:id/name/slug/description/pm_only。description 暂不用(抽屉一行放不下)。
interface DiscourseSidebarTag {
  id?: number;
  name?: string;
  slug?: string;
  pm_only?: boolean;
}

export class AuthService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  async getCurrentUser(): Promise<NetworkResult<User | undefined>> {
    const response: NetworkResult<string> = await this.bridge.getJson(CURRENT_SESSION_PATH);
    if (!response.success) {
      // 匿名会话在 Discourse 上是 404 + 空 body(SessionController#current 的 render body: nil,
      // status: 404),不是 200 + current_user:null。这是「确认未登录」的正向信号,必须与
      // 「请求没成功」区分开:上层(RootTabPage/NotificationService)对失败一律保留上一次登录态,
      // 若把这条 404 当失败上抛,登出后登录态永远清不掉,只能杀进程重启。
      // 同时要求 challengeState=NONE:CF 若用 404 壳子返回挑战页,仍按失败走过盾链路,不误判成登出。
      if (response.statusCode === CURRENT_SESSION_ANONYMOUS_STATUS && response.challengeState === ChallengeState.NONE) {
        // `_t` 还在就不算确认登出。Discourse 的 `_t` 每约 10 分钟轮换一次,宿主长时间不导航时
        // cookie 仓里的 `_t` 可能已被服务端作废,但进程的磁盘快照/内存里还留着旧值——此时服务端
        // 对 /session/current.json 回 404 不代表登录真没了,只是 `_t` 陈旧。若把 404 直接当「确认
        // 未登录」上抛,通知轮询每约 5 分钟的一次 404 就会把登录态掀掉(用户感知 = 用着用着被登出、
        // 老要重新登录),而且没有任何迟滞/重试。只有 `_t` 确实不在了,404 才是确认登出;`_t` 还在
        // 一律按失败处理,上层保留上一次登录态,宿主下一次导航/重载拿到新 `_t` 后自然恢复。
        if (WebSessionManager.hasCookie('_t')) {
          return forwardFailure<User | undefined>(response);
        }
        return {
          success: true,
          statusCode: response.statusCode,
          challengeState: response.challengeState,
          data: undefined
        };
      }
      return forwardFailure<User | undefined>(response);
    }

    if (response.data === undefined) {
      return unexpectedResponse<User | undefined>(response.statusCode, response.challengeState, '站点当前会话响应为空。');
    }

    try {
      const payload: DiscourseCurrentSessionResponse = JSON.parse(response.data) as DiscourseCurrentSessionResponse;
      const sourceUser: DiscourseCurrentUser | null | undefined = payload.current_user;
      if (sourceUser === undefined || sourceUser === null) {
        return {
          success: true,
          statusCode: response.statusCode,
          challengeState: response.challengeState,
          data: undefined
        };
      }

      if (typeof sourceUser.id !== 'number' || typeof sourceUser.username !== 'string') {
        return unexpectedResponse<User | undefined>(response.statusCode, response.challengeState, '站点当前用户响应字段无效。');
      }

      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: {
          id: sourceUser.id,
          username: sourceUser.username,
          displayName: sourceUser.name,
          avatarTemplate: sourceUser.avatar_template,
          animatedAvatar: sourceUser.animated_avatar ? sourceUser.animated_avatar : undefined,
          unreadNotifications: typeof sourceUser.all_unread_notifications_count === 'number'
            ? sourceUser.all_unread_notifications_count
            : (typeof sourceUser.unread_notifications === 'number' ? sourceUser.unread_notifications : 0),
          unreadHighPriorityNotifications: typeof sourceUser.unread_high_priority_notifications === 'number' ? sourceUser.unread_high_priority_notifications : 0,
          draftCount: typeof sourceUser.draft_count === 'number' ? sourceUser.draft_count : 0,
          sidebarTags: this.mapSidebarTags(sourceUser.sidebar_tags),
          sidebarCategoryIds: this.mapSidebarCategoryIds(sourceUser.sidebar_category_ids),
          trustLevel: typeof sourceUser.trust_level === 'number' ? sourceUser.trust_level : 0,
          admin: sourceUser.admin === true,
          moderator: sourceUser.moderator === true
        }
      };
    } catch (error) {
      return unexpectedResponse<User | undefined>(response.statusCode, response.challengeState, '站点当前会话响应不是有效 JSON。');
    }
  }

  // 退出登录:DELETE /session/{username}(CSRF/Cookie 由 bridge 同源自动处理)。
  // 成功后由调用方触发 SessionEventBus,走与登录相同的会话刷新链路。
  async logout(username: string): Promise<NetworkResult<boolean>> {
    const response: NetworkResult<string> = await this.bridge.deleteForm(`/session/${encodeURIComponent(username)}`, '');
    if (!response.success) {
      return {
        success: false,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        error: response.error
      };
    }
    return {
      success: true,
      statusCode: response.statusCode,
      challengeState: response.challengeState,
      data: true
    };
  }

  /**
   * 侧栏自选标签。做三件事:字段校验、丢掉私信专用标签(pm_only 在公开列表里筛不出任何东西,
   * 与标签联想的处理一致)、**按名字排序**。
   *
   * 排序不是我们自己加的规则:服务端给的是话题数倒序(serialize_tags 的 `order(topic_count desc)`),
   * 但网页版在前端把它按名字重排了(frontend/discourse/app/models/user.js 的 sidebarTags getter
   * `sort((a, b) => a.name.localeCompare(b.name))`),侧栏看到的就是名字序。这里跟着排才对得上。
   * 放在这层而不是渲染时排:每次会话检查只排一次,抽屉每帧 build 都排就浪费了。
   */
  private mapSidebarTags(sourceTags?: DiscourseSidebarTag[]): SidebarTag[] {
    if (sourceTags === undefined) {
      return [];
    }
    const tags: SidebarTag[] = [];
    for (let index: number = 0; index < sourceTags.length; index++) {
      const item: DiscourseSidebarTag = sourceTags[index];
      if (item.pm_only === true || typeof item.name !== 'string' || item.name.length === 0) {
        continue;
      }
      tags.push({
        id: typeof item.id === 'number' ? item.id : undefined,
        name: item.name,
        slug: typeof item.slug === 'string' && item.slug.length > 0 ? item.slug : undefined
      });
    }
    tags.sort((left: SidebarTag, right: SidebarTag) => NameCollator.compare(left.name, right.name));
    return tags;
  }

  private mapSidebarCategoryIds(sourceIds?: number[]): number[] {
    if (sourceIds === undefined) {
      return [];
    }
    return sourceIds.filter((id: number) => typeof id === 'number' && id > 0);
  }
}
