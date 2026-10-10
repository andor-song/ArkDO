import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { TopicCategory } from '../../models/Topic';
import { UserHistoryItem, UserHistoryPage } from '../../models/UserProfile';
import { RelativeTime } from '../../common/utils/RelativeTime';
import { ChallengeState, JsonNetworkClient, NetworkErrorCode, NetworkResult } from '../../services/network/NetworkTypes';
import { CategoryIndex } from '../../services/site/CategoryIndex';
import { UserProfileService } from '../../services/user/UserProfileService';
import { TopicMetadataBadges } from '../components/TopicBadges';
import { LoadStateView } from '../components/LoadStateView';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { ListFooter } from '../components/ListFooter';
import { FaIconDefinition, FaIconView, getFaIcon } from '../components/FaIcon';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';

const LOG_TAG: string = '[ArkDO][UserHistoryListPage]';
const PAGE_PADDING: number = 16;

// 他人主页统计格三个插件页共用的通用列表(solved 走独立 SolvedPostsPage,样式更专门):
// - boosts    -> /discourse-boosts/users/{u}/boosts-given.json        (游标 before_boost_id)
// - reactions -> /discourse-reactions/posts/reactions.json?username=U (游标 before_reaction_user_id)
// - votes     -> /topics/voted-by/{u}.json?page=N                    (标准 topic list)
// 三种数据在服务层统一压成 UserHistoryItem(标题+摘要+分类+时间),这里只负责渲染与分页。
// 行结构对齐 SolvedPostsPage:图标 + 标题 + 分类/时间 + 摘要,点击跳对应主题。
@Component
export struct UserHistoryListPage {
  // 窗口常驻全屏布局:根列自行避让状态栏(padding 在带背景的根列上,背景填满状态栏条)。
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  isArkWebReady: boolean = false;
  username: string = '';
  // 'boosts' | 'reactions' | 'votes'(数据源与图标/文案都按它分支)。
  kind: string = 'boosts';
  // 页标题(如「Boost · 12」;count<=0 时只显示种类名)。
  pageTitle: string = '';
  onBack: () => void = () => {};
  onOpenTopic: (topicId: number, title: string, postNumber?: number) => void = () => {};

  @State private items: UserHistoryItem[] = [];
  @State private categories: TopicCategory[] = [];
  @State private isInitialLoading: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private isLoadingMore: boolean = false;
  @State private hasMore: boolean = true;
  @State private loadFailed: boolean = false;
  @State private message: string = '';
  private service?: UserProfileService = undefined;
  private categoryIndex: CategoryIndex = new CategoryIndex();
  private loading: boolean = false;
  // 分页游标:boost/reaction = 上一页最后一条的 id(boosts 的 boost id / reactions 的 ref id),
  // 投票 = 0 起的页码。每次成功加载后更新(见 updateCursor),loadMore 直接拿它当下页入参。
  private nextCursor: number = 0;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    if (this.bridge) {
      this.service = new UserProfileService(this.bridge);
    }
    this.loadCategories();
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
          mainTitle: this.pageTitle.length > 0 ? this.pageTitle : this.kindTitle()
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
    // 只当标题栏容器用,不参与分栏(分栏由 RootTabPage 根 Navigation 负责)。默认 Auto 会在
    // 宽度 ≥600vp 时自切 Split——平板横屏右详情栏就会多出一条可拖的分割线,菜单也被挤到线左边。
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg'))
  }

  @Builder
  private Content() {
    if (this.items.length === 0) {
      Column() {
        LoadStateView({
          isLoading: this.isInitialLoading,
          loadingText: '加载中…',
          message: this.message.length > 0 ? this.message : '加载失败',
          showRetry: this.loadFailed,
          emptyTitle: this.emptyTitle(),
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
            ForEach(this.items, (item: UserHistoryItem, index: number) => {
              ListItem() {
                this.HistoryRow(item)
              }
            }, (item: UserHistoryItem, index: number) => `${item.topicId ?? 0}_${index}`)

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

  // 行:种类图标 + 右侧(标题 / 分类+时间 / 摘要)。全局主语已是目标用户,行内不再出头像。
  // 图标语义:boosts=火箭、reactions=拇指、votes=投票选框,统一染品牌色。
  @Builder
  private HistoryRow(item: UserHistoryItem) {
    Row() {
      FaIconView({ icon: this.kindIcon(), color: $r('app.color.ld_accent'), iconSize: 15 })
        .margin({ top: 2, right: 7 })

      Column() {
        Text(item.title)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Row() {
          if (this.getCategoryFor(item.categoryId)) {
            TopicMetadataBadges({
              category: this.getCategoryFor(item.categoryId),
              parentCategory: this.getParentCategoryFor(item.categoryId),
              tags: []
            })
              .layoutWeight(1)
          } else {
            Blank()
          }
          if (item.createdAt && item.createdAt.length > 0) {
            Text(RelativeTime.fromNow(item.createdAt))
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 8 })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ top: 5 })

        // boost/回应才有摘要(votes 只有主题没有正文切面)。
        if (item.excerpt.length > 0) {
          Text(item.excerpt)
            .fontSize(14)
            .fontColor($r('app.color.text_body'))
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(21)
            .width('100%')
            .padding({ left: 10 })
            .border({ width: { left: 2 }, color: { left: $r('app.color.ld_accent') } })
            .margin({ top: 8 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 12, bottom: 13 })
    .alignItems(VerticalAlign.Top)
    .onClick(() => {
      if (item.topicId !== undefined && item.topicId > 0) {
        // votes 只到主题;boost/回应尽量落到对应楼层(无 postNumber 时落到主题)。
        this.onOpenTopic(item.topicId, item.title, item.postNumber);
      }
    })
  }

  // ==================== 数据加载 ====================

  private async loadInitial(): Promise<void> {
    if (!this.service || this.loading) {
      if (!this.service) {
        this.message = '正在准备请求环境';
      }
      this.isRefreshing = false;
      return;
    }
    const isFirstLoad: boolean = this.items.length === 0;
    this.loading = true;
    this.isInitialLoading = isFirstLoad;
    this.isRefreshing = !isFirstLoad;
    this.loadFailed = false;

    const result: NetworkResult<UserHistoryPage> = await this.fetchPage();
    this.loading = false;
    this.isInitialLoading = false;
    this.isRefreshing = false;

    if (!result.success || result.data === undefined) {
      this.loadFailed = true;
      this.message = result.error?.message ? result.error.message : '加载失败，请重试';
      Log.i(`${LOG_TAG} initial load failed user=${this.username} kind=${this.kind} status=${result.statusCode}`);
      return;
    }

    this.items = result.data.items;
    this.hasMore = result.data.hasMore;
    this.updateCursor(result.data);
    this.message = '';
    Log.i(`${LOG_TAG} initial loaded user=${this.username} kind=${this.kind} count=${this.items.length} hasMore=${this.hasMore}`);
  }

  private async loadMore(): Promise<void> {
    if (!this.service || this.loading || !this.hasMore || this.items.length === 0) {
      return;
    }
    this.loading = true;
    this.isLoadingMore = true;

    const result: NetworkResult<UserHistoryPage> = await this.fetchPage();
    this.loading = false;
    this.isLoadingMore = false;

    if (!result.success || result.data === undefined) {
      Log.i(`${LOG_TAG} load more failed user=${this.username} kind=${this.kind} status=${result.statusCode}`);
      return;
    }
    if (result.data.items.length === 0) {
      this.hasMore = false;
      return;
    }
    this.items = this.items.concat(result.data.items);
    this.hasMore = result.data.hasMore;
    this.updateCursor(result.data);
    // 游标去重防线:服务端若返回了与上一页重复的第一条(游标维护出错),按同 topicId+title 天然幂等,
    // 这里不额外去重——游标正确时不会重复;万一重复也只是同一行多显示一次,不影响跳转。
  }

  // 三种数据源的分页取数统一在这里,入参游标由 nextCursor 持有:
  // - boosts   :before_boost_id = 上一页最后一条 boost 的 id;首页 0。
  // - reactions:before_reaction_user_id = 上一页最后一条 ref 的 id;首页 0。
  // - votes    :page = 0 起的页码(标准 topic list 翻页)。
  private async fetchPage(): Promise<NetworkResult<UserHistoryPage>> {
    if (!this.service) {
      return {
        success: false,
        statusCode: 0,
        challengeState: ChallengeState.NONE,
        error: { code: NetworkErrorCode.NETWORK_FAILURE, message: '请求环境未就绪', requiresChallenge: false }
      };
    }
    if (this.kind === 'reactions') {
      return this.service.getReactionsGiven(this.username, this.nextCursor);
    } else if (this.kind === 'votes') {
      return this.service.getVotedTopics(this.username, this.nextCursor);
    }
    return this.service.getBoostsGiven(this.username, this.nextCursor);
  }

  // 加载成功后推进游标:boost/reaction 取本页最后一条 item 的 cursor(服务层已把源 id 塞进去),
  // 投票页页码 +1。空页(hasMore 已假)不再推进,后续 loadMore 会被 hasMore 挡住。
  private updateCursor(data: UserHistoryPage): void {
    if (this.kind === 'votes') {
      this.nextCursor += 1;
      return;
    }
    const last: UserHistoryItem | undefined = data.items.length > 0 ? data.items[data.items.length - 1] : undefined;
    if (last && typeof last.cursor === 'number' && last.cursor > 0) {
      this.nextCursor = last.cursor;
    }
  }

  private async loadCategories(): Promise<void> {
    const loaded: TopicCategory[] | null = await this.categoryIndex.loadIfNeeded(
      this.bridge as JsonNetworkClient, this.isArkWebReady, this.categories.length > 0, LOG_TAG);
    if (loaded) {
      this.categories = loaded;
    }
  }

  // ==================== 展示辅助 ====================

  private kindTitle(): string {
    if (this.kind === 'reactions') {
      return '回应';
    } else if (this.kind === 'votes') {
      return '投票';
    }
    return 'Boost';
  }

  private emptyTitle(): string {
    if (this.kind === 'reactions') {
      return '还没有给出回应';
    } else if (this.kind === 'votes') {
      return '还没有投过票';
    }
    return '还没有 Boost';
  }

  // 图标语义:boost 火箭、回应拇指、投票选框;取不到定义时回退空。
  private kindIcon(): FaIconDefinition {
    let id: string = 'rocket';
    if (this.kind === 'reactions') {
      id = 'thumbs-up';
    } else if (this.kind === 'votes') {
      id = 'check-to-slot';
    }
    const def = getFaIcon(id);
    return def ? def : { id: id, rawfilePath: '' };
  }

  private getCategoryFor(categoryId?: number): TopicCategory | undefined {
    return CategoryIndex.find(this.categories, categoryId);
  }

  private getParentCategoryFor(categoryId?: number): TopicCategory | undefined {
    return CategoryIndex.findParent(this.categories, categoryId);
  }
}
