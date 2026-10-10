import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { FollowListPage, FollowUserItem } from '../../models/UserProfile';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { UserProfileService } from '../../services/user/UserProfileService';
import { UserRelationService } from '../../services/user/UserRelationService';
import { User } from '../../models/User';
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
import { FaIconView, getFaIcon } from '../components/FaIcon';

const LOG_TAG: string = '[ArkDO][FollowersListPage]';
const PAGE_PADDING: number = 16;
const AVATAR_SIZE: number = 44;

// 关注/粉丝列表(discourse-follow 插件):GET /u/{username}/followers.json 与 /following.json。
// 每行 = 头像 + 昵称/用户名 + 关注按钮;按 page 翻页。行内关注 toggle 走 UserRelationService。
@Component
export struct FollowersListPage {
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  isArkWebReady: boolean = false;
  username: string = '';
  // 'followers' | 'following':决定端点与文案("粉丝"/"关注")。
  kind: string = 'followers';
  pageTitle: string = '关注列表';
  onBack: () => void = () => {};
  onOpenUser: (user: User) => void = () => {};

  @State private items: FollowUserItem[] = [];
  @State private isInitialLoading: boolean = false;
  @State private isRefreshing: boolean = false;
  @State private isLoadingMore: boolean = false;
  @State private hasMore: boolean = true;
  @State private loadFailed: boolean = false;
  @State private message: string = '';
  private profileService?: UserProfileService = undefined;
  private relationService?: UserRelationService = undefined;
  // 每行关注请求在途锁:@{username} -> true。请求飞行中再点忽略。
  private followPendingByUser: Map<string, boolean> = new Map();
  private loading: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    if (this.bridge) {
      this.profileService = new UserProfileService(this.bridge);
      this.relationService = new UserRelationService(this.bridge);
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
          mainTitle: this.pageTitle
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
    if (this.items.length === 0) {
      Column() {
        LoadStateView({
          isLoading: this.isInitialLoading,
          loadingText: '加载中…',
          message: this.message.length > 0 ? this.message : '加载失败',
          showRetry: this.loadFailed,
          emptyTitle: this.kind === 'followers' ? '还没有粉丝' : '还没有关注任何人',
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
            ForEach(this.items, (item: FollowUserItem, index: number) => {
              ListItem() {
                this.FollowRow(item, index)
              }
            }, (item: FollowUserItem, index: number) => `${item.user.username}_${index}`)

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

  // 单行:头像 + 昵称/用户名 + 右侧关注按钮。头像/昵称点击进对方主页,按钮点击 toggle 关注。
  @Builder
  private FollowRow(item: FollowUserItem, index: number) {
    Row() {
      UserAvatar({ user: item.user, avatarSize: AVATAR_SIZE })
        .margin({ right: 12 })

      Column() {
        Text(this.displayNameOf(item))
          .width('100%')
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(`@${item.user.username}`)
          .width('100%')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ right: 10 })

      this.FollowButton(item, index)
    }
    .width('100%')
    .padding({ left: PAGE_PADDING, right: PAGE_PADDING, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onOpenUser(item.user);
    })
  }

  // 关注按钮:请求中转圈;已关注 = user-check + 主题蓝 +「已关注」,未关注 = user-plus + 主文字色 +「关注」。
  // 不弹确认框(关注是低风险正向操作;列表里确认框也太吵),点一下即翻转。
  @Builder
  private FollowButton(item: FollowUserItem, index: number) {
    Button({ type: ButtonType.Capsule, stateEffect: true }) {
      if (this.followPendingByUser.get(item.user.username) === true) {
        LoadingProgress()
          .width(14)
          .height(14)
          .color(item.isFollowed ? $r('app.color.ld_accent') : $r('app.color.text_body'))
      } else {
        Row({ space: 4 }) {
          FaIconView({
            icon: getFaIcon(item.isFollowed ? 'user-check' : 'user-plus'),
            iconSize: 12,
            color: item.isFollowed ? $r('app.color.ld_accent') : $r('app.color.text_body')
          })
          Text(item.isFollowed ? '已关注' : '关注')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(item.isFollowed ? $r('app.color.ld_accent') : $r('app.color.text_body'))
        }
        .alignItems(VerticalAlign.Center)
      }
    }
    .height(30)
    .padding({ left: 13, right: 13 })
    .backgroundColor(item.isFollowed ? $r('app.color.surface_muted') : $r('app.color.ld_accent'))
    .borderRadius(15)
    .border(item.isFollowed ? { width: 1, color: $r('app.color.border') } : { width: 0 })
    .onClick(() => {
      this.toggleFollow(item, index);
    })
  }

  private displayNameOf(item: FollowUserItem): string {
    return item.user.displayName && item.user.displayName.length > 0 ? item.user.displayName : item.user.username;
  }

  // ==================== 数据加载 ====================

  private async loadInitial(): Promise<void> {
    if (!this.profileService || this.loading) {
      this.message = '正在准备请求环境';
      this.isRefreshing = false;
      return;
    }
    const isFirstLoad: boolean = this.items.length === 0;
    this.loading = true;
    this.isInitialLoading = isFirstLoad;
    this.isRefreshing = !isFirstLoad;
    this.loadFailed = false;

    const result: NetworkResult<FollowListPage> = await this.profileService.getFollowList(this.username, this.kind as 'followers' | 'following', 0);
    this.loading = false;
    this.isInitialLoading = false;
    this.isRefreshing = false;

    if (!result.success || result.data === undefined) {
      this.loadFailed = true;
      this.message = result.error?.message ? result.error.message : '加载失败，请重试';
      Log.i(`${LOG_TAG} initial load failed kind=${this.kind} status=${result.statusCode}`);
      return;
    }

    this.items = result.data.items;
    this.hasMore = result.data.hasMore;
    this.message = '';
    Log.i(`${LOG_TAG} initial loaded kind=${this.kind} count=${this.items.length} hasMore=${this.hasMore}`);
  }

  private async loadMore(): Promise<void> {
    if (!this.profileService || this.loading || !this.hasMore || this.items.length === 0) {
      return;
    }
    this.loading = true;
    this.isLoadingMore = true;

    const page: number = Math.floor(this.items.length / 100);
    const result: NetworkResult<FollowListPage> =
      await this.profileService.getFollowList(this.username, this.kind as 'followers' | 'following', page);
    this.loading = false;
    this.isLoadingMore = false;

    if (!result.success || result.data === undefined) {
      Log.i(`${LOG_TAG} load more failed kind=${this.kind} status=${result.statusCode}`);
      return;
    }
    if (result.data.items.length === 0) {
      this.hasMore = false;
      return;
    }
    this.items = this.items.concat(result.data.items);
    this.hasMore = result.data.hasMore;
  }

  // ==================== 关注 toggle ====================

  private toggleFollow(item: FollowUserItem, index: number): void {
    if (!this.relationService || this.followPendingByUser.get(item.user.username) === true) {
      return;
    }
    this.followPendingByUser.set(item.user.username, true);
    const wouldFollow: boolean = !item.isFollowed;
    const task: Promise<NetworkResult<boolean>> = wouldFollow
      ? this.relationService.followUser(item.user.username)
      : this.relationService.unfollowUser(item.user.username);
    task.then((result: NetworkResult<boolean>) => {
      this.followPendingByUser.set(item.user.username, false);
      // 直接改行对象:FollowUserItem 是列表数组元素,改了要整组赋值才能触发重绘。
      if (result.success && this.items[index]) {
        const updated: FollowUserItem[] = this.items.slice();
        updated[index] = { user: item.user, isFollowed: wouldFollow };
        this.items = updated;
      }
    });
  }
}
