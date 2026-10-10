import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { MessageInboxPage as MessageInboxData, MessageThread } from '../../models/Message';
import { User } from '../../models/User';
import { RelativeTime } from '../../common/utils/RelativeTime';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
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

const LOG_TAG: string = '[ArkDO][MessageInboxPage]';
const PAGE_PADDING: number = 16;
const AVATAR_SIZE: number = 44;
// 服务端固定 50 条/页;翻页号从 1 起。
const PAGE_SIZE: number = 50;

// 私信收件箱:GET /u/{username}/messages.json 的会话列表。
// 行 = 参与者头像 + 会话标题 + 副行(参与者/@回复数/时间) + 未读蓝点。
// 点行进原生主题详情页(TopicDetailPage,私信会话就是主题)。
@Component
export struct MessageInboxPage {
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  isArkWebReady: boolean = false;
  username: string = '';
  onBack: () => void = () => {};
  onOpenTopic: (topicId: number, title: string) => void = () => {};

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
    .backgroundColor($r('app.color.page_bg'))
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
            }, (item: MessageThread, index: number) => `msg_${item.topicId}_${index}`)

            ListItem() {
              ListFooter({ isLoading: this.isLoadingMore, hasMore: this.hasMore })
            }
          }
          .divider({ strokeWidth: 1, color: $r('app.color.border'), startMargin: 0, endMargin: 0 })
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
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 14, bottom: 14 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onOpenTopic(item.topicId, item.title);
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
      this.message = result.error?.message ? result.error.message : '加载失败，请重试';
      Log.i(`${LOG_TAG} initial load failed status=${result.statusCode}`);
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
