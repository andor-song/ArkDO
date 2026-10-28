import { UIContext } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { Log } from '../logging/Log';
import { AppConstants } from '../../common/constants/AppConstants';
import { showToast, TOAST_SHORT_MS } from '../../common/utils/Toast';
import { Topic } from '../../models/Topic';
import { ImageShareService } from '../content/ImageShareService';
import { JsonNetworkClient, NetworkResult } from '../network/NetworkTypes';
import { friendlyFailure, rawFailure } from '../network/UserFacingError';
import { LoginGate } from '../session/LoginGate';
import { buildTopicShareText, buildTopicUrl } from './TopicLink';
import { TopicService } from './TopicService';

const LOG_TAG: string = '[ArkDO][TopicRowActions]';

// 依赖一律闭包惰性读取,与 PostActions 同一条理由:列表页在字段初始化器里 new 本类时,
// 父组件注入的 bridge prop 还没覆盖默认值,按值捕获会拿到未连接宿主的空壳(那边实测翻过车)。
export type RowBridgeFn = () => JsonNetworkClient | undefined;
export type RowToastFn = (message: string, duration: number) => void;
export type RowUIFn = () => UIContext;

/**
 * 帖子列表行长按菜单的三个动作:复制链接 / 分享 / 标为已读。
 *
 * 为什么收成一处而不是三个列表各写一份:这三件事在首页、已读页、搜索浮层里需要的东西
 * 完全一样(按当前站点拼链接、系统剪贴板、系统分享面板、topics/bulk 上报、失败文案走
 * UserFacingError),差别只在「哪几项进菜单」。动作放这里,「进不进菜单」由列表注入回调
 * 决定(见 TopicListItem 的 onCopyLink / onShareTopic / onMarkRead)。
 */
export class TopicRowActions {
  private getBridge: RowBridgeFn;
  private toast: RowToastFn;
  private getUI: RowUIFn;

  constructor(getBridge: RowBridgeFn, toast: RowToastFn, getUI: RowUIFn) {
    this.getBridge = getBridge;
    this.toast = toast;
    this.getUI = getUI;
  }

  // 主题永久链接(不带楼号)。站点未配置或 id 非法时返回空串,调用方据此决定菜单要不要这一项。
  topicUrl(topic: Topic): string {
    return buildTopicUrl(AppConstants.BASE_URL, topic.slug, topic.id);
  }

  /** 复制主题链接到剪贴板。 */
  copyLink(topic: Topic): void {
    const url: string = this.topicUrl(topic);
    if (url.length === 0) {
      // 不是「复制失败」而是「现在还没有可复制的东西」:换站过程中 BASE_URL 可能是空串。
      this.toast('暂时拿不到该帖子的链接', TOAST_SHORT_MS);
      Log.i(`${LOG_TAG} copy link skipped topicId=${topic.id} baseUrlLen=${AppConstants.BASE_URL.length}`);
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        this.toast('已复制链接', TOAST_SHORT_MS);
      }).catch(() => {
        // 剪贴板被系统拒(后台窗口/权限)时用户只需知道没复制上;链接文本已拼好,细节留日志。
        Log.i(`${LOG_TAG} set clipboard failed topicId=${topic.id}`);
        this.toast('复制失败，请稍后重试', TOAST_SHORT_MS);
      });
    } catch (error) {
      Log.i(`${LOG_TAG} pasteboard threw topicId=${topic.id} error=${JSON.stringify(error)}`);
      this.toast('复制失败，请稍后重试', TOAST_SHORT_MS);
    }
  }

  /** 分享主题:标题 + 永久链接,拉起系统分享面板(与详情页分享楼层同一套)。 */
  share(topic: Topic): void {
    const url: string = this.topicUrl(topic);
    const text: string = buildTopicShareText(topic.title, url);
    if (text.trim().length === 0) {
      this.toast('这条帖子暂时没有可分享的内容', TOAST_SHORT_MS);
      return;
    }
    const host: common.Context | undefined = this.getUI().getHostContext() as common.Context | undefined;
    if (host === undefined) {
      Log.i(`${LOG_TAG} share aborted topicId=${topic.id} host context missing`);
      this.toast('分享失败，请稍后重试', TOAST_SHORT_MS);
      return;
    }
    // 分享面板要的是 UIAbilityContext,不是 UIContext —— 与详情页 sharePost 同一取法。
    const abilityContext: common.UIAbilityContext = host as common.UIAbilityContext;
    ImageShareService.shareText(abilityContext, text, topic.title).then((ok: boolean) => {
      if (!ok) {
        this.toast('分享失败，请稍后重试', 2000);
      }
    });
  }

  /**
   * 标为已读(整帖)。成功后就地清掉蓝点与未读药丸:
   * Topic 是 @Observed、行走 @ObjectLink 绑定,改字段即精准重绘本行,不必重建列表。
   *
   * 刻意不做乐观更新:dismiss_posts 是一次纯 SQL 更新,失败时必须让蓝点留着 ——
   * 先清再补会把「没标记成功」伪装成「已读」,用户下次进来才发现帖子还在。
   */
  async markRead(topic: Topic): Promise<boolean> {
    if (!LoginGate.ensureLoggedIn()) {
      // 未登录:LoginGate 已经把登录流程拉起来了,这里只负责不发请求。
      return false;
    }
    const bridge: JsonNetworkClient | undefined = this.getBridge();
    if (bridge === undefined) {
      Log.i(`${LOG_TAG} mark read aborted topicId=${topic.id} bridge not ready`);
      this.toast('正在准备请求环境，请稍后重试', TOAST_SHORT_MS);
      return false;
    }
    const result: NetworkResult<boolean> = await new TopicService(bridge).markTopicRead(topic.id);
    if (!result.success) {
      Log.i(`${LOG_TAG} mark read failed topicId=${topic.id} ${rawFailure<boolean>(result)}`);
      this.toast(friendlyFailure<boolean>(result, { subject: '已读状态', action: '标记' }), 2000);
      return false;
    }
    topic.unseen = false;
    topic.unreadPosts = 0;
    this.toast('已标为已读', TOAST_SHORT_MS);
    Log.i(`${LOG_TAG} marked read topicId=${topic.id}`);
    return true;
  }
}
