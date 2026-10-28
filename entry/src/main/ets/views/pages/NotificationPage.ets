import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { NotificationItem } from '../../models/Notification';
import { NotificationApi } from '../../services/notification/NotificationApi';
import { NotificationEventBus } from '../../services/notification/NotificationEventBus';
import {
  NOTIFICATION_FILTER_ALL, NOTIFICATION_FILTER_OPTIONS, NotificationFilterOption,
  notificationFilterTypeNames
} from '../../services/notification/NotificationFilter';
import {
  NotificationTarget, NotificationTargetKind, resolveNotificationTarget
} from '../../services/notification/NotificationRouting';
import { LoginGate } from '../../services/session/LoginGate';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { friendlyFailure, rawFailure } from '../../services/network/UserFacingError';
import { NotificationListItem } from '../components/NotificationListItem';
import { showToast as promptToast, TOAST_SHORT_MS } from '../../common/utils/Toast';
import { LoadStateView } from '../components/LoadStateView';
import { ChoiceChip } from '../components/ChoiceChip';
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
// 筛选条高度 = 紧凑胶囊 30 + 下外边距 8。横向 List 在 Column 里量不出自身高度,
// 不给死值就塌成 0(与 CategoryDrawer 的 FEED_CHIP_STRIP_HEIGHT 同因)。
const CHIP_STRIP_HEIGHT: number = 38;

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
  // 聊天类通知进原生聊天页(与私信收件箱同一个入口);「有人关注了你」这类没有帖子的通知
  // 进发起人主页。分流规则本身在 NotificationRouting,页面只负责执行。
  onOpenChat: (channelId: number, title: string) => void = () => {};
  onOpenUser: (username: string) => void = () => {};

  @State private items: NotificationItem[] = [];
  // 顶部的类型筛选。选中项直接拼进请求的 filter_by_types,**不是本地过滤**:
  // 本地只拿得到已加载的那一页,筛完只会「看起来变少了」,而不是「真的只有这些」。
  @State private filterKey: string = NOTIFICATION_FILTER_ALL;
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
  private chipScroller: Scroller = new Scroller();
  // 「整页重载」撞上在途请求时记的账:请求收尾后补拉一次(与首页 pendingSessionRefresh 同一手法)。
  // 触发者是切筛选与下拉刷新,两者都必须落到「最终状态与界面一致」,不能被静默丢弃。
  private pendingReload: boolean = false;
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
        // 筛选条在空态也要在:某个类型恰好一条通知都没有时,如果空态不带 chips,
        // 用户就被困在「暂无通知」里换不回别的筛选(只能退出重进)。
        // 未登录除外:任何筛选都是 403,chips 只会把一个说不清的入口摆在那儿。
        if (!this.notLoggedIn) {
          Blank()
            .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))
          this.FilterChips()
        }
        // 未登录:显示「去登录」引导(带登录按钮),而不是「加载失败」。登录成功后订阅回调自动重拉。
        if (this.notLoggedIn) {
          this.LoginGuide()
        } else {
          LoadStateView({
            isLoading: this.isInitialLoading,
            loadingText: '加载中…',
            message: this.message.length > 0 ? this.message : '通知加载失败,请重试',
            showRetry: this.loadFailed,
            // 筛选后的空态要说「这一类没有」而不是「没有通知」,并且给一句换回去的话——
            // 与已读/未读那几个 feed 的空态同一口径(参见 1.0.12 的改动)。
            emptyTitle: this.filterKey === NOTIFICATION_FILTER_ALL ? '暂无通知' : '这个类型下暂无通知',
            emptySubtitle: this.filterKey === NOTIFICATION_FILTER_ALL ? '' : '换其他类型看看,或点「全部」',
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
      // 列表分支的筛选条挂在分组头部(而不是列表外面的固定行):
      // 本页用 position(y:-spacer) 让列表顶到状态栏、内容从标题栏下滑过,固定行会跟这个
      // 负偏移打架;挂头部则与占位 Blank 同一段,滚动关系保持单一。
      this.FilterChips()
    }
    .width('100%')
  }

  // 单行横向滚动的类型 chips(照抄分类抽屉那套:换行方案会把列表顶下去,且增减入口时整块布局跟着跳)。
  @Builder
  private FilterChips() {
    Column() {
      List({ scroller: this.chipScroller }) {
        ForEach(NOTIFICATION_FILTER_OPTIONS, (option: NotificationFilterOption) => {
          ListItem() {
            ChoiceChip({
              label: option.label,
              selected: this.filterKey === option.key,
              compact: true,
              onTap: () => {
                this.switchFilter(option.key);
              }
            })
          }
        }, (option: NotificationFilterOption) => `nf${option.key}`)
      }
      .listDirection(Axis.Horizontal)
      // Fade 而不是 Spring:横向列表的弹簧回弹会在边界露出一段空白,这里两边贴着的就是页面边缘。
      .edgeEffect(EdgeEffect.Fade)
      .scrollBar(BarState.Off)
      .width('100%')
      .height(CHIP_STRIP_HEIGHT)
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .alignItems(HorizontalAlign.Start)
  }

  private hasUnread(): boolean {
    for (let index: number = 0; index < this.items.length; index++) {
      if (!this.items[index].read) {
        return true;
      }
    }
    return false;
  }

  // 首次加载 / 下拉刷新 / 切换筛选:recent=true(服务端顺带 bump seen_reviewable 等「看过」状态)。
  //
  // 刻意**不再** publish({ unread: 0 })。原先那一句把铃铛按「进过页面」清零,而服务端的未读口径是
  // all_unread_notifications_count = 逐条 read=false 的条数;recent 只动 seen 不动 read,
  // 于是本地那个 0 是假象,下一次轮询 / MessageBus 拿权威值一覆盖,数字就「反弹」回原样
  // (进通知页 → 返回 → 数字涨回去)。现在只有「确实把某条读掉了」才动数字,见 handleItemClick。
  private async loadInitial(): Promise<void> {
    if (!this.api) {
      this.message = '正在准备请求环境';
      this.isRefreshing = false;
      return;
    }
    if (this.loading) {
      // 撞上在途请求(下拉刷新 / 翻页 / 上一次筛选没结束):记账,请求收尾后补拉。
      // 直接 return 的话 chips 已经高亮却没有重新取数 —— 又是一处「点了没反应」。
      this.pendingReload = true;
      this.isRefreshing = false;
      return;
    }
    // Refresh 单向绑定:必须自己把 isRefreshing 置 true(刷新已有列表时)、结束再置 false,
    // 靠这个跳变收起下拉 spinner。首次空列表用 isInitialLoading 走中心 loading。
    const isFirstLoad: boolean = this.items.length === 0;
    // 请求发出前的筛选键。在途期间用户可能已经切了筛选,回来时按这个值决定结果要不要采纳。
    const requestedFilter: string = this.filterKey;
    this.loading = true;
    this.isInitialLoading = isFirstLoad;
    this.isRefreshing = !isFirstLoad;
    this.loadFailed = false;
    try {
      const result: NetworkResult<NotificationItem[]> =
        await this.api.load(PAGE_SIZE, 0, true, notificationFilterTypeNames(requestedFilter));

      if (requestedFilter !== this.filterKey) {
        // 在途期间切了筛选:这批是旧筛选的结果,丢掉(补拉在 finally 里排队)。
        Log.i(`${LOG_TAG} drop stale initial load ${requestedFilter} -> ${this.filterKey}`);
        return;
      }

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
        // 与其余列表页同一套分类:挑战/断网/请求环境没就绪/站点限流各有各的说法,
        // 不再一律「通知加载失败」——那会让「还没选论坛」看起来像网络故障。
        this.message = friendlyFailure(result, { subject: '通知', action: '加载' });
        Log.i(`${LOG_TAG} initial load failed ${rawFailure(result)}`);
        return;
      }

      this.items = result.data;
      this.hasMore = result.data.length >= PAGE_SIZE;
      this.message = '';
    } finally {
      this.loading = false;
      this.isInitialLoading = false;
      this.isRefreshing = false;
      this.drainPendingReload();
    }
  }

  private async loadMore(): Promise<void> {
    if (!this.api || this.loading || !this.hasMore || this.items.length === 0) {
      return;
    }
    this.loading = true;
    this.isLoadingMore = true;

    const requestedFilter: string = this.filterKey;
    // 偏移在发请求那一刻取:翻页必须带同一份筛选条件,否则这一页是「别的集合」的第 N 条。
    const offset: number = this.items.length;
    try {
      const result: NetworkResult<NotificationItem[]> =
        await this.api.load(PAGE_SIZE, offset, false, notificationFilterTypeNames(requestedFilter));

      if (requestedFilter !== this.filterKey) {
        // 翻页途中切了筛选:这一页属于旧筛选,不能接进列表(新旧混排比少一页难看得多)。
        Log.i(`${LOG_TAG} drop stale page ${requestedFilter} -> ${this.filterKey}`);
        return;
      }
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
    } finally {
      this.loading = false;
      this.isLoadingMore = false;
      this.drainPendingReload();
    }
  }

  // 把在途期间攒下的重载补做掉。放 finally 而不是各条 return 前:
  // loadInitial 有四个出口,漏一个就永久停在「chip 高亮了但列表还是旧的」那种状态。
  private drainPendingReload(): void {
    if (!this.pendingReload) {
      return;
    }
    this.pendingReload = false;
    this.loadInitial();
  }

  // 切筛选:先换高亮、清空结果集,再重取。清空不是多余的一步 ——
  // 旧筛选的列表留在屏幕上,用户看不出筛选生效了(而 loading 是中心转圈,不覆盖列表)。
  private switchFilter(key: string): void {
    if (key === this.filterKey) {
      return;
    }
    this.filterKey = key;
    this.items = [];
    this.hasMore = true;
    this.message = '';
    this.notLoggedIn = false;
    this.loadInitial();
  }

  // 点某行:标记已读(本地即时改 + 发请求 + 让角标跟着减一条) → 按通知类型分流跳转。
  private handleItemClick(item: NotificationItem): void {
    if (!item.read) {
      this.setRead(item.id);
      // 角标跟着减一条:服务端未读数就是「逐条 read=false 的条数」,读掉一条该少一条。
      // decrementUnread 自带 0/空窗保护(还没拿到权威值时不乱减),所以这里可以放心调。
      NotificationEventBus.decrementUnread(item.highPriority === true);
      if (this.api) {
        this.api.markRead(item.id);
      }
    }
    const target: NotificationTarget = resolveNotificationTarget(item);
    if (target.kind === NotificationTargetKind.CHAT && target.channelId !== undefined) {
      // 聊天通知:进原生聊天页。以前按 topic_id 开帖子——每条聊天消息背后那句占位主题
      // 点进去是空的,也读不出上下文。
      this.onOpenChat(target.channelId, item.title);
      return;
    }
    if (target.kind === NotificationTargetKind.TOPIC && target.topicId !== undefined) {
      this.onOpenTopic(target.topicId, item.slug, item.title, target.postNumber);
      return;
    }
    if (target.kind === NotificationTargetKind.USER && target.username !== undefined) {
      // 「有人关注了你」(discourse-follow 800)没有帖子,该去发起人主页。
      this.onOpenUser(target.username);
      return;
    }
    // 到这儿才是真的没有可去的地方(徽章 / 投票释放 / 站点问题这类系统通知)。
    // 以前静默,现在给一句话:用户分不出「这条通知本来就没页面」和「app 卡住了」。
    Log.i(`${LOG_TAG} no target id=${item.id} type=${item.type}`);
    promptToast(this.getUIContext(), '这条通知没有可打开的页面', TOAST_SHORT_MS);
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
      slug: src.slug, chatChannelId: src.chatChannelId, url: src.url, highPriority: src.highPriority,
      iconId: src.iconId, iconColor: src.iconColor
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
