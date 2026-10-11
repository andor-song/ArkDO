import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { NotificationItem } from '../../models/Notification';
import { NotificationApi } from '../../services/notification/NotificationApi';
import { NotificationEventBus } from '../../services/notification/NotificationEventBus';
import { LoginGate } from '../../services/session/LoginGate';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { NotificationListItem } from '../components/NotificationListItem';
import { LoadStateView } from '../components/LoadStateView';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { ListFooter } from '../components/ListFooter';
import { BOTTOM_TAB_BAR_HEIGHT } from '../../common/theme/Metrics';
import { APP_IS_WIDE_STORAGE_KEY } from '../../common/utils/BreakpointManager';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';

const LOG_TAG: string = '[ArkDO][NotificationPage]';
const PAGE_SIZE: number = 30;

@Component
export struct NotificationPage {
  // 宽屏(平板横屏 Split 双栏)下底部导航栏隐藏,列表尾部不再让位(BOTTOM_TAB_BAR_HEIGHT)。
  @StorageProp(APP_IS_WIDE_STORAGE_KEY) private appIsWide: boolean = false;
  // 窗口常驻全屏布局:根列自行避让状态栏(padding 在带背景的根列上,背景填满状态栏条)。
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  isArkWebReady: boolean = false;
  onBack: () => void = () => {};
  // postNumber:通知指向的具体楼层,详情页据此定位并高亮;无楼层的通知(徽章等)为 undefined。
  onOpenTopic: (topicId: number, slug: string | undefined, title: string, postNumber?: number) => void = () => {};

  @State private items: NotificationItem[] = [];
  @State private isInitialLoading: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private isLoadingMore: boolean = false;
  @State private hasMore: boolean = true;
  @State private loadFailed: boolean = false;
  @State private message: string = '';
  // 未登录态:通知接口是登录专享(403 not_logged_in),此时显示「去登录」引导而不是「加载失败」。
  @State private notLoggedIn: boolean = false;
  private api?: NotificationApi = undefined;
  private loading: boolean = false;
  private scroller: Scroller = new Scroller();
  // 登录成功自动重拉:用户从本空态点「立即登录」→ 登录页登录 → 回来不用手动重进就能看到列表。
  private unsubscribeBecameLoggedIn?: () => void = undefined;

  aboutToAppear(): void {
    if (this.bridge) {
      this.api = new NotificationApi(this.bridge);
    }
    // 登录成功后自动重拉:通知接口 403 not_logged_in 时本页显示「去登录」引导;用户在登录页
    // 完成登录返回,这里无需再手动重进页面就把列表拉出来。重复订阅是幂等的(先退订旧的)。
    if (this.unsubscribeBecameLoggedIn) {
      this.unsubscribeBecameLoggedIn();
      this.unsubscribeBecameLoggedIn = undefined;
    }
    this.unsubscribeBecameLoggedIn = LoginGate.subscribeBecameLoggedIn(() => {
      this.notLoggedIn = false;
      // 登录态刚翻真:直接重拉首页列表(此时 cookie 已带 _t,不会再见 403)。
      this.loadInitial();
    });
    this.loadInitial();
  }

  aboutToDisappear(): void {
    if (this.unsubscribeBecameLoggedIn) {
      this.unsubscribeBecameLoggedIn();
      this.unsubscribeBecameLoggedIn = undefined;
    }
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
          mainTitle: '通知'
        },
        backIcon: {
          icon: $r('sys.symbol.chevron_left'),
          label: '返回',
          action: () => {
            this.onBack();
          }
        },
        menu: this.hasUnread() ? {
          value: [{
            content: {
              icon: $r('sys.symbol.checkmark'),
              label: '全部已读',
              isEnabled: true,
              action: () => {
                this.markAllRead();
              }
            }
          }]
        } : undefined
      }
    })
    .bindToScrollable([this.scroller])
    .titleMode(HdsNavigationTitleMode.MINI)
    // 只当标题栏容器用,不参与分栏(分栏由 RootTabPage 根 Navigation 负责)。默认 Auto 会在
    // 宽度 ≥600vp 时自切 Split——平板横屏右详情栏就会多出一条可拖的分割线,菜单也被挤到线左边。
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_gray'))
  }

  @Builder
  private Content() {
    if (this.items.length === 0) {
      Column() {
        // 未登录:显示「去登录」引导(带登录按钮),而不是「加载失败」。登录成功后订阅回调自动重拉。
        if (this.notLoggedIn) {
          this.LoginGuide()
        } else {
          LoadStateView({
            isLoading: this.isInitialLoading,
            loadingText: '加载中…',
            message: this.message.length > 0 ? this.message : '通知加载失败,请重试',
            showRetry: this.loadFailed,
            emptyTitle: '暂无通知',
            onRetry: () => {
              this.loadInitial();
            }
          })
        }
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      Refresh({ refreshing: this.isRefreshing, promptText: '刷新中' }) {
        List({ scroller: this.scroller }) {
          ListItemGroup({ header: this.TitleBarListHeader }) {
            ForEach(this.items, (item: NotificationItem) => {
              ListItem() {
                NotificationListItem({
                  item: item,
                  cardMode: true,
                  onItemClick: (clicked: NotificationItem) => {
                    this.handleItemClick(clicked);
                  }
                })
              }
            }, (item: NotificationItem) => `${item.id}_${item.read}`)

            ListItem() {
              ListFooter({
                isLoading: this.isLoadingMore,
                hasMore: this.hasMore,
                endText: '已到底',
                accentColor: $r('app.color.brand'),
                textColor: $r('app.color.text_secondary')
              })
            }
          }
        }
        .width('100%')
        .height(`calc(100% + ${immersiveTitleBarContentTopSpacer(this.sysTopInset)}vp)`)
        .position({ x: 0, y: -immersiveTitleBarContentTopSpacer(this.sysTopInset) })
        .clip(false)
        .scrollBar(BarState.Off)
        // 一级 tab 页底部有飞书式导航栏悬浮覆盖;列表尾部留出 TabBar 高度,最后一条不被遮。
        // 宽屏双栏下 TabBar 隐藏,不预留封底空档。
        .contentEndOffset(this.appIsWide ? 0 : BOTTOM_TAB_BAR_HEIGHT)
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

  private hasUnread(): boolean {
    for (let index: number = 0; index < this.items.length; index++) {
      if (!this.items[index].read) {
        return true;
      }
    }
    return false;
  }

  // 首次加载 / 下拉刷新:recent=true(服务端 bump seen 清红点),并同步铃铛置零。
  private async loadInitial(): Promise<void> {
    if (!this.api || this.loading) {
      if (!this.api) {
        this.message = '正在准备请求环境';
      }
      // 若因重复触发提前返回,也要收起可能已被下拉手势拉起的刷新态。
      this.isRefreshing = false;
      return;
    }
    // Refresh 单向绑定:必须自己把 isRefreshing 置 true(刷新已有列表时)、结束再置 false,
    // 靠这个跳变收起下拉 spinner。首次空列表用 isInitialLoading 走中心 loading。
    const isFirstLoad: boolean = this.items.length === 0;
    this.loading = true;
    this.isInitialLoading = isFirstLoad;
    this.isRefreshing = !isFirstLoad;
    this.loadFailed = false;

    const result: NetworkResult<NotificationItem[]> = await this.api.load(PAGE_SIZE, 0, true);
    this.loading = false;
    this.isInitialLoading = false;
    this.isRefreshing = false;

    if (!result.success || result.data === undefined) {
      if (result.notLoggedIn) {
        // 未登录(403 not_logged_in):这是「引导登录」而非「重试」——显示登录按钮,不显示重试。
        this.notLoggedIn = true;
        this.loadFailed = false;
        this.message = '登录后即可查看通知';
        Log.i(`${LOG_TAG} initial load not logged in status=${result.statusCode}`);
        return;
      }
      this.notLoggedIn = false;
      this.loadFailed = true;
      this.message = '通知加载失败,请重试';
      Log.i(`${LOG_TAG} initial load failed status=${result.statusCode}`);
      return;
    }

    this.items = result.data;
    this.hasMore = result.data.length >= PAGE_SIZE;
    this.message = '';
    // 已看见(seen 已 bump):把铃铛未读清零,保留私信高优先级计数不动。
    NotificationEventBus.publish({ unread: 0, highPriority: NotificationEventBus.current().highPriority });
  }

  private async loadMore(): Promise<void> {
    if (!this.api || this.loading || !this.hasMore || this.items.length === 0) {
      return;
    }
    this.loading = true;
    this.isLoadingMore = true;

    const result: NetworkResult<NotificationItem[]> = await this.api.load(PAGE_SIZE, this.items.length, false);
    this.loading = false;
    this.isLoadingMore = false;

    if (!result.success || result.data === undefined) {
      Log.i(`${LOG_TAG} load more failed status=${result.statusCode}`);
      return;
    }

    if (result.data.length === 0) {
      this.hasMore = false;
      return;
    }
    this.items = this.items.concat(result.data);
    this.hasMore = result.data.length >= PAGE_SIZE;
  }

  // 点某行:乐观标记已读 → 跳转帖子;标记请求 fire-and-forget。
  private handleItemClick(item: NotificationItem): void {
    if (!item.read) {
      this.setRead(item.id);
      if (this.api) {
        this.api.markRead(item.id);
      }
    }
    if (item.topicId !== undefined) {
      this.onOpenTopic(item.topicId, item.slug, item.title, item.postNumber);
    }
  }

  private setRead(id: number): void {
    const next: NotificationItem[] = [];
    for (let index: number = 0; index < this.items.length; index++) {
      const cur: NotificationItem = this.items[index];
      if (cur.id === id && !cur.read) {
        next.push(this.cloneRead(cur));
      } else {
        next.push(cur);
      }
    }
    this.items = next;
  }

  private async markAllRead(): Promise<void> {
    // 未登录:拦截并弹登录页,不发请求(全部标记已读)。
    if (!LoginGate.ensureLoggedIn()) {
      return;
    }
    const next: NotificationItem[] = [];
    for (let index: number = 0; index < this.items.length; index++) {
      next.push(this.items[index].read ? this.items[index] : this.cloneRead(this.items[index]));
    }
    this.items = next;
    NotificationEventBus.publish({ unread: 0, highPriority: 0 });
    if (this.api) {
      await this.api.markAllRead();
    }
  }

  private cloneRead(src: NotificationItem): NotificationItem {
    return {
      id: src.id, type: src.type, read: true, createdAt: src.createdAt,
      actorName: src.actorName, actorUsername: src.actorUsername, avatarTemplate: src.avatarTemplate,
      actionText: src.actionText, title: src.title, topicId: src.topicId, postNumber: src.postNumber,
      slug: src.slug, iconId: src.iconId, iconColor: src.iconColor
    };
  }
  // 未登录引导空态:与「我的」页一致 —— 圆环人像 + 标题 + 副标题 + 「立即登录」按钮。
  // 登录入口走全局 LoginGate.requestLogin():RootTabPage 已订阅,会弹出登录页;登录成功后
  // 本页订阅的 subscribeBecameLoggedIn 自动重拉(见 aboutToAppear),无需手动返回重进。
  @Builder
  private LoginGuide() {
    Column({ space: 0 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.bell'))
          .fontSize(32)
          .fontColor([$r('app.color.text_faint')])
      }
      .width(68)
      .height(68)
      .justifyContent(FlexAlign.Center)
      .borderRadius(34)
      .border({ width: 1, color: $r('app.color.border') })

      Text('未登录')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 16 })

      Text('登录后即可查看回复、@与私信通知')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .margin({ top: 6 })
        .padding({ left: 24, right: 24 })

      Button('立即登录')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.ld_accent'))
        .height(42)
        .padding({ left: 44, right: 44 })
        .borderRadius(21)
        .margin({ top: 22 })
        .onClick(() => {
          LoginGate.requestLogin();
        })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
  }

}
