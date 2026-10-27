import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { MessageInboxPage as MessageInboxData, MessageThread } from '../../models/Message';
import { User } from '../../models/User';
import { RelativeTime } from '../../common/utils/RelativeTime';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { friendlyFailure, rawFailure } from '../../services/network/UserFacingError';
import { MessageService } from '../../services/message/MessageService';
import { LoadStateView } from '../components/LoadStateView';
import { UserAvatar } from '../components/UserAvatar';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { ListFooter } from '../components/ListFooter';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';
import { CARD_RADIUS } from '../../common/theme/Metrics';

const LOG_TAG: string = '[ArkDO][MessageInboxPage]';
const PAGE_PADDING: number = 16;
const AVATAR_SIZE: number = 44;
// 服务端固定 50 条/页;翻页号从 1 起。
const PAGE_SIZE: number = 50;

// 私信收件箱:列表页。数据源自适应(MessageService 内部:优先 Chat 直聊频道,
// 否则回退传统 PM 收件箱)。
// 行 = 参与者头像 + 会话标题 + 副行(参与者/@回复数/时间) + 未读蓝点。
// 点行进目的地按行类型:chat 会话(channelId 有效) → 原生聊天页;否则原生主题详情页。
@Component
export struct MessageInboxPage {
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  isArkWebReady: boolean = false;
  username: string = '';
  onBack: () => void = () => {};
  onOpenTopic: (topicId: number, title: string) => void = () => {};
  // 打开原生聊天页(带直聊频道 id 与标题)。chat 会话走它,代替旧 WebView /chat/c/...。
  onOpenChat: (channelId: number, title: string) => void = () => {};

  @State private threads: MessageThread[] = [];
  @State private isInitialLoading: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private isLoadingMore: boolean = false;
  @State private hasMore: boolean = true;
  @State private loadFailed: boolean = false;
  @State private message: string = '';
  private service?: MessageService = undefined;
  private loading: boolean = false;
  private scroller: Scroller = new Scroller();
  // 当前按下的会话行(topicId,0 = 无)。ThreadRow 是 @Builder,不能自带 @State,
  // 所以按下态由页面持有:按下时记 id、抬起/取消时清空。
  @State private pressedThreadId: number = 0;

  aboutToAppear(): void {
    if (this.bridge) {
      this.service = new MessageService(this.bridge);
    }
    this.loadInitial();
  }

  build() {
    HdsNavigation() {
      this.Content()
    }
    .titleBar({
      avoidLayoutSafeArea: requiresHdsLayoutSafeAreaAvoidance(ImmersiveLightArea.TITLE_BAR),
      enableComponentSafeArea: requiresHdsComponentSafeArea(ImmersiveLightArea.TITLE_BAR),
      style: buildImmersiveTitleBarStyle({ enableRefreshOffsetChange: true }),
      content: {
        title: {
          mainTitle: '私信'
        },
        backIcon: {
          icon: $r('sys.symbol.chevron_left'),
          label: '返回',
          action: () => {
            this.onBack();
          }
        }
      }
    })
    .bindToScrollable([this.scroller])
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_gray'))
  }

  @Builder
  private Content() {
    if (this.threads.length === 0) {
      Column() {
        LoadStateView({
          isLoading: this.isInitialLoading,
          loadingText: '加载中…',
          message: this.message.length > 0 ? this.message : '加载失败',
          showRetry: this.loadFailed,
          emptyTitle: '还没有私信',
          onRetry: () => {
            this.loadInitial();
          }
        })
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      Refresh({ refreshing: this.isRefreshing, promptText: '刷新中' }) {
        List({ scroller: this.scroller }) {
          ListItemGroup({ header: this.TitleBarListHeader }) {
            ForEach(this.threads, (item: MessageThread, index: number) => {
              ListItem() {
                this.ThreadRow(item, index)
              }
            // key 必须并入这一行实际渲染到的一切(本仓 ForumsPage/DohSettingsPage 都踩过):
            // 按下态由页面级 @State 驱动,key 里不带它时 ForEach 复用旧行、opacity 不会刷新。
            }, (item: MessageThread, index: number) =>
              `msg_${item.topicId}_${index}_${this.pressedThreadId === item.topicId ? 'p' : 'n'}`)

            ListItem() {
              ListFooter({ isLoading: this.isLoadingMore, hasMore: this.hasMore })
            }
          }
        }
        .width('100%')
        .height(`calc(100% + ${immersiveTitleBarContentTopSpacer(this.sysTopInset)}vp)`)
        .position({ x: 0, y: -immersiveTitleBarContentTopSpacer(this.sysTopInset) })
        .clip(false)
        .scrollBar(BarState.Off)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .onReachEnd(() => {
          this.loadMore();
        })
      }
      .width('100%')
      .height('100%')
      .clip(false)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      .onRefreshing(() => {
        this.loadInitial();
      })
    }
  }

  @Builder
  private TitleBarListHeader() {
    Column() {
      Blank()
        .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))
    }
    .width('100%')
  }

  // 单行:头像 + 标题/副行 + 未读点。头像取第一个参与者(通常即对方)。
  @Builder
  private ThreadRow(item: MessageThread, index: number) {
    Row() {
      Stack({ alignContent: Alignment.TopEnd }) {
        UserAvatar({ user: this.avatarUserOf(item), avatarSize: AVATAR_SIZE })
        // 未读蓝点:右上角小圆点,与首页未读角标同色系。
        if (item.unseen) {
          Circle()
            .width(10)
            .height(10)
            .fill($r('app.color.ld_accent'))
            .margin({ top: -2, right: -2 })
        }
      }
      .margin({ right: 12 })

      Column() {
        Text(item.title)
          .width('100%')
          .fontSize(16)
          .fontWeight(item.unseen ? FontWeight.Bold : FontWeight.Normal)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.subtitleOf(item))
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    // 卡片模式(飞书/微信式浅灰底+白卡):与帖子列表卡片一致,贴边圆角卡、卡间留缝。
    // 内部 padding 走 PAGE_PADDING(16),保持原有排版比例。
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(CARD_RADIUS)
    .margin({ top: 6, bottom: 6 })
    // 按下反馈:与帖子/通知列表同一套(opacity 0.7,不做动画)。
    .opacity(this.pressedThreadId === item.topicId ? 0.7 : 1)
    .onTouch((event: TouchEvent) => {
      if (event.type === TouchType.Down) {
        this.pressedThreadId = item.topicId;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        this.pressedThreadId = 0;
      }
    })
    .onClick(() => {
      // 兜底清按下态(见 TopicListItem 同处注释):滚动抢走手势时 Cancel 不一定到。
      this.pressedThreadId = 0;
      // 聊天会话(chat 源)走原生聊天页;传统私信主题走原生详情页。
      if (item.chatUrl !== undefined) {
        this.onOpenChat(item.topicId, item.title);
      } else {
        this.onOpenTopic(item.topicId, item.title);
      }
    })
  }

  // 副行:参与者(或 @某用户) · N 回复 · 相对时间。
  private subtitleOf(item: MessageThread): string {
    const parts: string[] = [];
    const participants: string = this.participantsLabel(item);
    if (participants.length > 0) {
      parts.push(participants);
    }
    if (item.postsCount > 0) {
      parts.push(`${item.postsCount} 条消息`);
    }
    const time: string = RelativeTime.fromNow(item.lastPostedAt);
    if (time.length > 0) {
      parts.push(time);
    }
    return parts.join(' · ');
  }

  // 参与者摘要:取前两人名字(「我」是当前登录者,列表接口不标注,直接取前两个名额),
  // 单人会话显示对方 @username。
  private participantsLabel(item: MessageThread): string {
    const users: User[] = item.participants;
    if (users.length === 0) {
      return '';
    }
    if (users.length === 1) {
      const only: User = users[0];
      return only.displayName && only.displayName.length > 0 ? only.displayName : `@${only.username}`;
    }
    const names: string[] = [];
    for (let idx: number = 0; idx < Math.min(2, users.length); idx++) {
      const u: User = users[idx];
      names.push(u.displayName && u.displayName.length > 0 ? u.displayName : u.username);
    }
    return names.join('、');
  }

  // 头像:取第一个参与者;列表接口没给参与者时退回白板头像(带占位名)。
  private avatarUserOf(item: MessageThread): User {
    if (item.participants.length > 0) {
      return item.participants[0];
    }
    return {
      id: 0,
      username: 'unknown',
      displayName: '私信'
    };
  }

  // ==================== 数据加载 ====================

  private async loadInitial(): Promise<void> {
    if (!this.service || this.loading) {
      this.message = '正在准备请求环境';
      this.isRefreshing = false;
      return;
    }
    const isFirstLoad: boolean = this.threads.length === 0;
    this.loading = true;
    this.isInitialLoading = isFirstLoad;
    this.isRefreshing = !isFirstLoad;
    this.loadFailed = false;

    const result: NetworkResult<MessageInboxData> = await this.service.getInbox(this.username, 1);
    this.loading = false;
    this.isInitialLoading = false;
    this.isRefreshing = false;

    if (!result.success || result.data === undefined) {
      this.loadFailed = true;
      this.message = friendlyFailure(result, { subject: '私信', action: '加载' });
      Log.i(`${LOG_TAG} initial load failed ${rawFailure(result)}`);
      return;
    }

    this.threads = result.data.threads;
    this.hasMore = result.data.hasMore;
    this.message = '';
    Log.i(`${LOG_TAG} initial loaded count=${this.threads.length} hasMore=${this.hasMore}`);
  }

  private async loadMore(): Promise<void> {
    if (!this.service || this.loading || !this.hasMore || this.threads.length === 0) {
      return;
    }
    this.loading = true;
    this.isLoadingMore = true;

    const page: number = Math.floor(this.threads.length / PAGE_SIZE) + 1;
    const result: NetworkResult<MessageInboxData> = await this.service.getInbox(this.username, page);
    this.loading = false;
    this.isLoadingMore = false;

    if (!result.success || result.data === undefined) {
      Log.i(`${LOG_TAG} load more failed status=${result.statusCode}`);
      return;
    }
    if (result.data.threads.length === 0) {
      this.hasMore = false;
      return;
    }
    this.threads = this.threads.concat(result.data.threads);
    this.hasMore = result.data.hasMore;
  }
}
