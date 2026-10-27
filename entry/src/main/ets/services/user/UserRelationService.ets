import { EndorsableCategoriesResult, EndorsableCategory } from '../../models/UserProfile';
import { ChallengeState, JsonNetworkClient, NetworkErrorCode, NetworkFailureKind, NetworkResult } from '../network/NetworkTypes';
import { forwardFailure, unexpectedFrom } from '../network/NetworkResults';

// 关注/认可等「对他人的写操作」。与只读的 UserProfileService 分开:
// 一个取数、一个改状态,混在一起职责不清。CSRF/cookie 由 bridge 同源自动处理。

interface DiscourseEndorsableCategory {
  id?: number;
  name?: string;
  color?: string;
}

interface DiscourseEndorsableResponse {
  categories?: DiscourseEndorsableCategory[];
  extras?: DiscourseEndorsableExtras;
}

interface DiscourseEndorsableExtras {
  remaining_endorsements?: number;
}

// 静音 / 忽略的纯逻辑层（档位、请求体、到期时间）。与网络调用分开，是为了能不碰 bridge 就单测
// —— 这一层写错的后果都是静默的：漏掉 expiring_at 会让服务端 500，档位拼错会被服务端
// 当成"非法值"回一句错误而不是失败得明显。
export const USER_RELATION_NORMAL: string = 'normal';
export const USER_RELATION_MUTED: string = 'mute';
export const USER_RELATION_IGNORED: string = 'ignore';

// 「忽略」在上游是**有到期时间**的（IgnoredUser.expiring_at 非空，且有定时任务清理过期项），
// 而「静音」没有。所以 ignore 必须带 expiring_at，缺了服务端会在 Time.parse(nil) 处抛。
export interface IgnoreDuration {
  label: string;
  days: number;
}

/**
 * 两档的**实际语义**（逐行核过上游，别照网页版的措辞猜）：
 *  · 静音 = 只跳过通知（post_alerter 用 `ignoring_or_muting_actor?` 直接 return）。
 *    内容照常出现 —— 上游没有任何"折叠静音用户发言"的服务端逻辑（`post.hidden?` 那套
 *    是员工隐藏帖，跟静音用户无关）。
 *  · 忽略 = 通知 + 可见性都受影响：列表里排除 TA 开的主题（topic.rb:763），
 *    帖内过滤 TA 的楼层但**保留一楼**（topic_view.rb:1145，避免整帖看起来空缺），
 *    并且**有到期时间**（`ignored_users.expiring_at` NOT NULL + 定时任务清过期项）。
 * 文案与勾选逻辑都按这份语义写，不要写得比它更强。
 */
export const IGNORE_DURATIONS: IgnoreDuration[] = [
  { label: '3 天', days: 3 },
  { label: '1 周', days: 7 },
  { label: '1 个月', days: 30 }
];

/**
 * 「一直忽略」用的到期时间：往后推 10 年。
 *
 * 为什么不用"真的无限"：上游 `expiring_at` 是 **NOT NULL** 列，没有"永不过期"这个表示法；
 * 网页版给的也只是"很长"。10 年足够覆盖任何实际使用周期，且随时能用「恢复正常」撤掉。
 */
export const IGNORE_FOREVER_DAYS: number = 3650;

/**
 * 生成 expiring_at 的取值（ISO8601 UTC）。
 *
 * 刻意由**调用方传入 now**而不是内部读系统时钟：这样可单测，且能一眼看出"客户端时钟偏了
 * 会怎样"——偏到过去会让忽略立刻到期（服务端定时任务直接删掉），所以用 UTC 的 ISO 串，
 * 与上游 `Time.parse` / `DateTime.parse` 都能吃的格式对齐，不带本地时区歧义。
 */
export function expiringAtFromNow(nowMs: number, days: number): string {
  return new Date(nowMs + days * 24 * 60 * 60 * 1000).toISOString();
}

/**
 * 拼 notification_level 的 form body。
 *
 * ignore 缺 expiringAt 时返回空串而不是"照样发"：服务端那边是
 * `IgnoredUser.create!(expiring_at: Time.parse(params[:expiring_at]))`，参数缺失会抛到 500，
 * 用户只看到一个"操作失败"。宁可在客户端拒发并留一行日志。
 */
export function buildUserRelationBody(relation: string, expiringAt: string): string {
  if (relation === USER_RELATION_IGNORED) {
    if (expiringAt.length === 0) {
      return '';
    }
    return `notification_level=ignore&expiring_at=${encodeURIComponent(expiringAt)}`;
  }
  if (relation === USER_RELATION_MUTED) {
    return 'notification_level=mute';
  }
  if (relation === USER_RELATION_NORMAL) {
    return 'notification_level=normal';
  }
  return '';
}

/**
 * 用户关系状态（三者互斥，由服务端保证）：normal / muted / ignored。
 *
 * 为什么自己判而不是直接读服务端给的单个字段：上游给的是**两个独立布尔**
 * （`muted`、`ignored`）+ 两个"能不能做"的开关（`can_mute_user`、`can_ignore_user`）。
 * 两者理论上可能同时为真（历史数据/并发），这里按 ignored > muted > normal 收敛成一个值，
 * 让 UI 只需要处理一种状态。
 */
export const USER_STATE_NORMAL: string = USER_RELATION_NORMAL;
export const USER_STATE_MUTED: string = USER_RELATION_MUTED;
export const USER_STATE_IGNORED: string = USER_RELATION_IGNORED;

export function userRelationStateOf(ignored: boolean | undefined, muted: boolean | undefined): string {
  if (ignored === true) {
    return USER_STATE_IGNORED;
  }
  if (muted === true) {
    return USER_STATE_MUTED;
  }
  return USER_STATE_NORMAL;
}

/**
 * 面板里的一行选项。
 *
 * 「忽略」在上游必须带到期时间，所以时长是**选项本身**而不是二级菜单：把 3 天 / 1 周 / 1 个月 /
 * 一直摊成四行，一眼看完，比"先选忽略、再选时长"少一次交互，也不需要再造一个浮层
 * （本页已有一个 bindSheet，同一条组件链上第二个 bindSheet 只会让前一个失效）。
 */
export interface UserRelationOption {
  // normal / mute / ignore
  relation: string;
  // ignore 的时长天数；非 ignore 为 0（此时请求不带 expiring_at）。
  days: number;
  label: string;
  hint: string;
  /**
   * 是否就是当前状态。
   *
   * 只有「恢复正常」在"当前本来就是 normal"时为真；静音也标、忽略**不标任何一档时长** ——
   * 因为服务端不告诉我们剩余天数（`ignored` 只是个布尔），标在其中任意一行都是撒谎的勾选。
   */
  current: boolean;
  /** 需要服务端 `can_ignore_user` / `can_mute_user` 才显示。 */
  requiresIgnorePermission: boolean;
  requiresMutePermission: boolean;
}

/**
 * 生成面板选项（顺序即展示顺序）。
 *
 * 权限位由服务端给的 `can_ignore_user` / `can_mute_user` 决定（上游 guardian：静音要 TL1+，
 * 忽略默认只给管理员/版主/TL2）。不给自己算一遍：那是站点可配置的组，客户端猜必错。
 */
export function buildUserRelationOptions(state: string, canMute: boolean,
  canIgnore: boolean): UserRelationOption[] {
  const options: UserRelationOption[] = [];
  if (canMute) {
    options.push({
      relation: USER_RELATION_MUTED,
      days: 0,
      label: '静音',
      hint: '不再收到 TA 的通知；TA 的发言照常出现',
      current: state === USER_STATE_MUTED,
      requiresIgnorePermission: false,
      requiresMutePermission: true
    });
  }
  if (canIgnore) {
    for (let index: number = 0; index < IGNORE_DURATIONS.length; index++) {
      const duration: IgnoreDuration = IGNORE_DURATIONS[index];
      options.push({
        relation: USER_RELATION_IGNORED,
        days: duration.days,
        label: `忽略 · ${duration.label}`,
        hint: '到期前看不到 TA 的发言：TA 的主题与楼层都消失（帖内一楼除外）',
        current: false,
        requiresIgnorePermission: true,
        requiresMutePermission: false
      });
    }
    options.push({
      relation: USER_RELATION_IGNORED,
      days: IGNORE_FOREVER_DAYS,
      label: '一直忽略',
      hint: '同上且不过期；可随时在这里恢复',
      current: false,
      requiresIgnorePermission: true,
      requiresMutePermission: false
    });
  }
  options.push({
    relation: USER_RELATION_NORMAL,
    days: 0,
    label: '恢复',
    hint: '取消静音与忽略，回到默认',
    current: state === USER_STATE_NORMAL,
    requiresIgnorePermission: false,
    requiresMutePermission: false
  });
  return options;
}

export class UserRelationService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  /**
   * 设置对某个用户的关系：静音 / 忽略 / 恢复正常。
   *
   * 端点 `PUT /u/{username}/notification_level.json`（上游 users#notification_level）。
   * 三态互斥由服务端保证：ignore 会先删 muted，mute 会先删 ignored，normal 两个都删 ——
   * 所以客户端**不需要**自己组合"先取消 A 再设 B"，多一次请求反而多一个失败中间态。
   *
   * 状态一律**等服务端回成功后**再由调用方改写（不做乐观更新）：静音/忽略是"你以为生效了
   * 其实没有"代价很高的事（继续收一堆通知，或从此看不到 TA 的话还以为是自己刷丢了）。
   */
  async setUserRelation(username: string, relation: string,
    expiringAt: string): Promise<NetworkResult<boolean>> {
    const body: string = buildUserRelationBody(relation, expiringAt);
    if (body.length === 0) {
      // 注意:unexpectedFrom 只从入参取 statusCode/challengeState,error 对象本身会被**丢弃**。
      // 所以分类必须作为实参传下去 —— 写在 error 字面量里看着像标了,实际没人读。
      return unexpectedFrom<boolean>({
        success: false, statusCode: 0, challengeState: ChallengeState.NONE,
        error: { code: NetworkErrorCode.UNEXPECTED_RESPONSE, message: '请求被客户端拦下：参数不完整。', requiresChallenge: false }
      }, `未知的用户关系档位或忽略缺少到期时间：${relation}`, '设置用户关系时参数不完整，请重试',
        NetworkFailureKind.LOCAL_ABORT);
    }
    const response: NetworkResult<string> = await this.bridge.putForm(
      `/u/${encodeURIComponent(username)}/notification_level.json`, body);
    return this.asBoolResult(response);
  }

  // 关注:PUT /follow/{username}.json,空 body(对齐官网 content-length:0)。响应 {"success":"OK"}。
  async followUser(username: string): Promise<NetworkResult<boolean>> {
    const response: NetworkResult<string> = await this.bridge.putJson(`/follow/${encodeURIComponent(username)}.json`);
    return this.asBoolResult(response);
  }

  // 取消关注:DELETE /follow/{username}.json,空 body。
  async unfollowUser(username: string): Promise<NetworkResult<boolean>> {
    const response: NetworkResult<string> = await this.bridge.deleteForm(`/follow/${encodeURIComponent(username)}.json`, '');
    return this.asBoolResult(response);
  }

  // 认可弹窗数据:GET /category-experts/endorsable-categories/{username}.json。
  // 返回可勾选的分类 + 今天还剩几次认可。
  async getEndorsableCategories(username: string): Promise<NetworkResult<EndorsableCategoriesResult>> {
    const path: string = `/category-experts/endorsable-categories/${encodeURIComponent(username)}.json`;
    const response: NetworkResult<string> = await this.bridge.getJson(path);
    if (!response.success) {
      return forwardFailure<EndorsableCategoriesResult>(response);
    }
    if (response.data === undefined) {
      return this.unexpected<EndorsableCategoriesResult>(response, '站点认可分类响应为空。');
    }
    try {
      const payload: DiscourseEndorsableResponse = JSON.parse(response.data) as DiscourseEndorsableResponse;
      const sourceCategories: DiscourseEndorsableCategory[] = payload.categories ? payload.categories : [];
      const categories: EndorsableCategory[] = [];
      for (let index: number = 0; index < sourceCategories.length; index++) {
        const source: DiscourseEndorsableCategory = sourceCategories[index];
        if (typeof source.id !== 'number' || typeof source.name !== 'string' || source.name.length === 0) {
          continue;
        }
        const category: EndorsableCategory = { id: source.id, name: source.name };
        if (source.color && source.color.length > 0) {
          category.color = source.color;
        }
        categories.push(category);
      }
      const remaining: number = payload.extras && typeof payload.extras.remaining_endorsements === 'number'
        ? payload.extras.remaining_endorsements
        : 0;
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: { categories: categories, remainingEndorsements: remaining }
      };
    } catch (error) {
      return this.unexpected<EndorsableCategoriesResult>(response, '站点认可分类响应不是有效 JSON。');
    }
  }

  // 提交认可:PUT /category-experts/endorse/{username}.json,form body categoryIds[]=4(可多选)。
  // 成功返回 {category_expert_endorsements:[...]},这里只需知道成功与否。
  async endorseCategories(username: string, categoryIds: number[]): Promise<NetworkResult<boolean>> {
    if (categoryIds.length === 0) {
      return {
        success: false,
        statusCode: 0,
        challengeState: ChallengeState.NONE,
        error: { code: NetworkErrorCode.UNEXPECTED_RESPONSE, message: '请至少选择一个类别。', requiresChallenge: false,
          // 这句本来就是写给用户看的(不是内部名词),所以同时标成 userReason:
          // 界面原样显示它,而不是退化成「检查网络」或「操作没发出去」。
          userReason: '请至少选择一个类别', failureKind: NetworkFailureKind.LOCAL_ABORT }
      };
    }
    const parts: string[] = [];
    for (let index: number = 0; index < categoryIds.length; index++) {
      parts.push(`categoryIds[]=${categoryIds[index]}`);
    }
    const body: string = parts.join('&');
    const path: string = `/category-experts/endorse/${encodeURIComponent(username)}.json`;
    const response: NetworkResult<string> = await this.bridge.putForm(path, body);
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

  // follow/unfollow 只判成败,响应体 {"success":"OK"} 不细解析。
  private asBoolResult(response: NetworkResult<string>): NetworkResult<boolean> {
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


  private unexpected<T>(response: NetworkResult<string>, message: string): NetworkResult<T> {
    return unexpectedFrom<T>(response, message);
  }
}
