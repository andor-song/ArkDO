import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { friendlyFailure, rawFailure } from '../../services/network/UserFacingError';
import { FollowFeedItem, FollowFeedPage, FollowFeedService } from '../../services/follow/FollowFeedService';
import { Log } from '../../services/logging/Log';
import { RelativeTime } from '../../common/utils/RelativeTime';
import { LoadStateView } from '../components/LoadStateView';
import { ListFooter } from '../components/ListFooter';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { BOTTOM_TAB_BAR_HEIGHT } from '../../common/theme/Metrics';
import { APP_IS_WIDE_STORAGE_KEY } from '../../common/utils/BreakpointManager';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';

const LOG_TAG: string = '[ArkDO][FollowingFeed]';

/**
 * 「关注动态」:关注的人最近发的楼层(discourse-follow 的 /follow/posts/{username})。
 *
 * 与主题列表的区别要说清:这是**楼层流**,同一个人在同一帖里连发两条就是两条;
 * 点一条打开的是那个主题并定位到那一楼,而不是从 1 楼看起。
 * 翻页按 `created_before` 游标走(服务端时间倒序),不是页码。
 */
@Component
export struct FollowingFeedPage {
  @StorageProp(APP_IS_WIDE_STORAGE_KEY) private appIsWide: boolean = false;
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  username: string = '';
  onBack: () => void = () => {};
  // 点一条 → 打开主题并定位到该楼(与首页点未读徽标同一条链路)。
  onOpenTopic: (topicId: number, slug: string | undefined, title: string, postNumber: number) => void =
    () => {};

  @State private items: FollowFeedItem[] = [];
  @State private isInitialLoading: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private isLoadingMore: boolean = false;
  @State private hasMore: boolean = true;
  @State private loadFailed: boolean = false;
  @State private message: string = '';
  @State private notLoggedIn: boolean = false;
  private loading: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadInitial();
  }

  private async loadInitial(): Promise<void> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined) {
      this.message = '正在准备请求环境';
      this.isRefreshing = false;
      return;
    }
    if (this.loading) {
      this.isRefreshing = false;
      return;
    }
    const isFirstLoad: boolean = this.items.length === 0;
    this.loading = true;
    this.isInitialLoading = isFirstLoad;
    this.isRefreshing = !isFirstLoad;
    this.loadFailed = false;
    const result: NetworkResult<FollowFeedPage> =
      await new FollowFeedService(bridge).load(this.username);
    this.loading = false;
    this.isInitialLoading = false;
    this.isRefreshing = false;
    if (!result.success || result.data === undefined) {
      if (result.notLoggedIn) {
        this.notLoggedIn = true;
        this.loadFailed = false;
        this.message = '登录后即可查看关注动态';
        return;
      }
      this.notLoggedIn = false;
      this.loadFailed = true;
      this.message = friendlyFailure(result, { subject: '关注动态', action: '加载' });
      Log.i(`${LOG_TAG} initial load failed ${rawFailure(result)}`);
      return;
    }
    this.items = result.data.items;
    this.hasMore = result.data.hasMore;
    this.message = '';
  }

  private async loadMore(): Promise<void> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined || this.loading || !this.hasMore || this.items.length === 0) {
      return;
    }
    this.loading = true;
    this.isLoadingMore = true;
    // 游标取最后一条的时间:服务端按 created_before 过滤,不认页码。
    const cursor: string = this.items[this.items.length - 1].createdAt;
    const result: NetworkResult<FollowFeedPage> =
      await new FollowFeedService(bridge).load(this.username, cursor);
    this.loading = false;
    this.isLoadingMore = false;
    if (!result.success || result.data === undefined) {
      Log.i(`${LOG_TAG} load more failed status=${result.statusCode}`);
      return;
    }
    if (result.data.items.length === 0) {
      this.hasMore = false;
      return;
    }
    this.items = this.items.concat(result.data.items);
    this.hasMore = result.data.hasMore;
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
          mainTitle: '关注动态'
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
    if (this.items.length === 0) {
      Column() {
        LoadStateView({
          isLoading: this.isInitialLoading,
          loadingText: '加载中…',
          message: this.message.length > 0 ? this.message : '关注动态加载失败，请重试',
          showRetry: this.loadFailed,
          emptyTitle: this.notLoggedIn ? '登录后即可查看' : '关注的人还没有新动态',
          emptySubtitle: this.notLoggedIn ? '' : '在他人主页点「关注」后，他们发的楼层会出现在这里',
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
          ListItem() {
            Column() {
              Blank()
                .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))
            }
            .width('100%')
          }

          ForEach(this.items, (item: FollowFeedItem) => {
            ListItem() {
              Column() {
                Text(item.title.length > 0 ? item.title : '（无标题主题）')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')

                if (item.excerpt.length > 0) {
                  Text(item.excerpt)
                    .fontSize(13)
                    .fontColor($r('app.color.text_secondary'))
                    .maxLines(2)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .margin({ top: 3 })
                }

                Row() {
                  Text(item.displayName !== undefined ? item.displayName : item.username)
                    .fontSize(12)
                    .fontColor($r('app.color.text_faint'))
                  Text(` · #${item.postNumber}`)
                    .fontSize(12)
                    .fontColor($r('app.color.text_faint'))
                  Blank()
                  Text(RelativeTime.fromNow(item.createdAt))
                    .fontSize(12)
                    .fontColor($r('app.color.text_faint'))
                }
                .width('100%')
                .margin({ top: 6 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding({ left: 14, right: 14, top: 12, bottom: 12 })
              .backgroundColor($r('app.color.card_bg'))
              .borderRadius(12)
              .margin({ left: 12, right: 12, top: 1, bottom: 1 })
              .onClick(() => {
                this.onOpenTopic(item.topicId, item.slug, item.title, item.postNumber);
              })
            }
          }, (item: FollowFeedItem) => `f${item.postId}`)

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
        .width('100%')
        .height(`calc(100% + ${immersiveTitleBarContentTopSpacer(this.sysTopInset)}vp)`)
        .position({ x: 0, y: -immersiveTitleBarContentTopSpacer(this.sysTopInset) })
        .clip(false)
        .scrollBar(BarState.Off)
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
}
