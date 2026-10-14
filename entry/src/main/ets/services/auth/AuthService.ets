import { SidebarTag, User } from '../../models/User';
import { NameCollator } from '../../common/utils/NameCollator';
import { AppConstants } from '../../common/constants/AppConstants';
import { ChallengeState, JsonNetworkClient, NetworkErrorCode, NetworkResult } from '../network/NetworkTypes';
import { WebSessionManager } from '../web/WebSessionManager';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';
import { CookiePresence } from '../web/CookieProbe';
import { SessionVerdict, judgeSession } from './SessionVerdict';

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

// 会话探测结果：把「这次响应说明什么」原样交给调用方，由上层决定迟滞策略
// （两振在 RootTabPage，见 SessionVerdict.shouldApplyAnonymous）。
export interface SessionProbe {
  verdict: SessionVerdict;
  user?: User;
}

export class AuthService {
  private bridge: JsonNetworkClient;
  private cookiePresence: (name: string) => CookiePresence;

  constructor(bridge: JsonNetworkClient, cookiePresence?: (name: string) => CookiePresence) {
    this.bridge = bridge;
    this.cookiePresence = cookiePresence !== undefined
      ? cookiePresence
      : (name: string): CookiePresence => WebSessionManager.getCookiePresenceForUrl(AppConstants.BASE_URL, name);
  }

  // 会话探测：把 /session/current.json 的一次响应翻译成四态，本身不做迟滞决策
  // （「要不要据此清登录态」由上层按 SessionVerdict.shouldApplyAnonymous 记账）。
  //
  // 旧实现在这里内联判断「404 且 hasCookie('_t') 为假 → 确认登出」，而 hasCookie 在
  // fetchCookieSync 抛异常时返回 false：一次 Cookie API 抖动就能把用户掀下线。
  // 现在探测异常 = UNKNOWN = 不下任何结论。
  async probeSession(): Promise<NetworkResult<SessionProbe>> {
    const response: NetworkResult<string> = await this.bridge.getJson(CURRENT_SESSION_PATH);
    const cookiePresence: CookiePresence = this.cookiePresence('_t');
    if (!response.success) {
      const verdict: SessionVerdict = judgeSession({
        transportOk: false,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        cookiePresence: cookiePresence,
        userPayloadPresent: false
      });
      if (verdict === 'anonymous-confirmed' || verdict === 'anonymous-unconfirmed') {
        return {
          success: true,
          statusCode: response.statusCode,
          challengeState: response.challengeState,
          data: { verdict: verdict }
        };
      }
      return forwardFailure<SessionProbe>(response);
    }

    if (response.data === undefined) {
      return unexpectedResponse<SessionProbe>(response.statusCode, response.challengeState, '站点当前会话响应为空。');
    }

    try {
      const payload: DiscourseCurrentSessionResponse = JSON.parse(response.data) as DiscourseCurrentSessionResponse;
      const sourceUser: DiscourseCurrentUser | null | undefined = payload.current_user;
      if (sourceUser === undefined || sourceUser === null) {
        return {
          success: true,
          statusCode: response.statusCode,
          challengeState: response.challengeState,
          data: { verdict: 'anonymous-confirmed' }
        };
      }
      if (typeof sourceUser.id !== 'number' || typeof sourceUser.username !== 'string') {
        return unexpectedResponse<SessionProbe>(response.statusCode, response.challengeState, '站点当前用户响应字段无效。');
      }
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: {
          verdict: 'logged-in',
          user: this.mapCurrentUser(sourceUser)
        }
      };
    } catch (error) {
      return unexpectedResponse<SessionProbe>(response.statusCode, response.challengeState, '站点当前会话响应不是有效 JSON。');
    }
  }

  // 兼容既有调用方(NotificationService 等)。只把**服务端正面证据**翻译成登出(data=undefined)：
  //   · logged-in            → success + user
  //   · anonymous-confirmed  → success + data=undefined(上层据此清态)
  //   · anonymous-unconfirmed→ 失败(上层保留上一次登录态,等第二振)
  //   · unknown              → 失败(同上)
  async getCurrentUser(): Promise<NetworkResult<User | undefined>> {
    const probe: NetworkResult<SessionProbe> = await this.probeSession();
    if (!probe.success) {
      return forwardFailure<User | undefined>(probe);
    }
    const data: SessionProbe | undefined = probe.data;
    if (data === undefined) {
      return unexpectedResponse<User | undefined>(probe.statusCode, probe.challengeState, '站点当前会话探测响应为空。');
    }
    if (data.verdict === 'logged-in') {
      return {
        success: true,
        statusCode: probe.statusCode,
        challengeState: probe.challengeState,
        data: data.user
      };
    }
    if (data.verdict === 'anonymous-confirmed') {
      return {
        success: true,
        statusCode: probe.statusCode,
        challengeState: probe.challengeState,
        data: undefined
      };
    }
    return unexpectedResponse<User | undefined>(probe.statusCode, probe.challengeState, '会话状态不明确(保留上一次登录态)。');
  }

  private mapCurrentUser(sourceUser: DiscourseCurrentUser): User {
    return {
      id: sourceUser.id as number,
      username: sourceUser.username as string,
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
    };
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
