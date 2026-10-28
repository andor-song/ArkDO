import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { TopicCategory } from '../../models/Topic';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { friendlyFailure, rawFailure } from '../../services/network/UserFacingError';
import { SiteService, SiteMetadata } from '../../services/site/SiteService';
import { MutePrefs, MuteService } from '../../services/site/MuteService';
import { Log } from '../../services/logging/Log';
import { LoadStateView } from '../components/LoadStateView';
import { ChoiceChip } from '../components/ChoiceChip';
import { showToast, TOAST_SHORT_MS } from '../../common/utils/Toast';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';

const LOG_TAG: string = '[ArkDO][MuteSettings]';

/**
 * 静音的版块与标签。
 *
 * 为什么不做「静音等级四档」:设置页这一处要解决的是「这个版块/标签别再来打扰我」,
 * 四档(静音/正常/跟踪/关注)是版块页里的细粒度偏好,搬到设置页只会让每行多出四个看不懂的选项。
 * 档位仍复用全站同一套编号:静音=0、正常=1。
 *
 * 静音只影响通知,不影响列表可见性——这一点必须写在页面上,否则用户会以为静音=隐藏。
 */
@Component
export struct MuteSettingsPage {
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  // 当前登录用户名:静音态要按用户读(/u/{username}.json)。由宿主从 currentUser 注入。
  username: string = '';
  onBack: () => void = () => {};

  @State private categories: TopicCategory[] = [];
  @State private mutedCategoryIds: number[] = [];
  @State private mutedTags: string[] = [];
  @State private tagInput: string = '';
  @State private loading: boolean = true;
  @State private loadFailed: boolean = false;
  @State private message: string = '';
  // 正在保存的版块 id(0=空闲)。保存期间禁掉该行开关,避免连点打出两个相反的请求。
  @State private savingCategoryId: number = 0;
  @State private savingTag: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined) {
      this.loading = false;
      this.loadFailed = true;
      this.message = '正在准备请求环境，请稍后重试';
      return;
    }
    this.loading = true;
    this.loadFailed = false;
    const site: NetworkResult<SiteMetadata> = await new SiteService(bridge).getSiteMetadata();
    if (!site.success || site.data === undefined) {
      this.loading = false;
      this.loadFailed = true;
      this.message = friendlyFailure(site, { subject: '版块列表', action: '加载' });
      Log.i(`${LOG_TAG} load categories failed ${rawFailure(site)}`);
      return;
    }
    this.categories = site.data.categories;
    const prefs: NetworkResult<MutePrefs> = await new MuteService(bridge).loadPrefs(this.username);
    this.loading = false;
    if (!prefs.success || prefs.data === undefined) {
      this.loadFailed = true;
      this.message = friendlyFailure(prefs, { subject: '静音设置', action: '加载' });
      Log.i(`${LOG_TAG} load mute prefs failed ${rawFailure(prefs)}`);
      return;
    }
    this.mutedCategoryIds = prefs.data.categoryIds;
    this.mutedTags = prefs.data.tags;
  }

  private isCategoryMuted(categoryId: number): boolean {
    return this.mutedCategoryIds.indexOf(categoryId) >= 0;
  }

  private parentNameOf(category: TopicCategory): string {
    if (category.parentCategoryId === undefined) {
      return '';
    }
    for (let index: number = 0; index < this.categories.length; index++) {
      if (this.categories[index].id === category.parentCategoryId) {
        return this.categories[index].name;
      }
    }
    return '';
  }

  private async toggleCategory(category: TopicCategory, muted: boolean): Promise<void> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined || this.savingCategoryId !== 0) {
      return;
    }
    this.savingCategoryId = category.id;
    const result: NetworkResult<boolean> = await new MuteService(bridge).setCategoryMuted(category.id, muted);
    this.savingCategoryId = 0;
    if (!result.success) {
      showToast(this.getUIContext(),
        friendlyFailure(result, { subject: '版块通知', action: '设置' }), 2000);
      Log.i(`${LOG_TAG} set category mute failed id=${category.id} muted=${muted} ${rawFailure(result)}`);
      // 失败时不动本地态:开关会被下一次重绘拉回原值(ArkUI 的 Toggle 由 isOn 驱动),
      // 用户看到的仍是「没改成功」而不是「改成功了但服务端没收到」。
      return;
    }
    const next: number[] = [];
    for (let index: number = 0; index < this.mutedCategoryIds.length; index++) {
      if (this.mutedCategoryIds[index] !== category.id) {
        next.push(this.mutedCategoryIds[index]);
      }
    }
    if (muted) {
      next.push(category.id);
    }
    this.mutedCategoryIds = next;
  }

  private async muteTagInput(): Promise<void> {
    const tag: string = this.tagInput.trim();
    if (tag.length === 0) {
      showToast(this.getUIContext(), '请输入标签名', TOAST_SHORT_MS);
      return;
    }
    const muted: boolean = await this.setTagMuted(tag, true);
    if (muted) {
      this.tagInput = '';
    }
  }

  private async setTagMuted(tag: string, muted: boolean): Promise<boolean> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined || this.savingTag) {
      return false;
    }
    this.savingTag = true;
    const result: NetworkResult<boolean> = await new MuteService(bridge).setTagMuted(tag, muted);
    this.savingTag = false;
    if (!result.success) {
      showToast(this.getUIContext(),
        friendlyFailure(result, { subject: '标签通知', action: '设置' }), 2000);
      Log.i(`${LOG_TAG} set tag mute failed tag=${tag} muted=${muted} ${rawFailure(result)}`);
      return false;
    }
    const next: string[] = [];
    for (let index: number = 0; index < this.mutedTags.length; index++) {
      if (this.mutedTags[index] !== tag) {
        next.push(this.mutedTags[index]);
      }
    }
    if (muted) {
      next.push(tag);
    }
    this.mutedTags = next;
    return true;
  }

  build() {
    HdsNavigation() {
      this.Content()
    }
    .titleBar({
      avoidLayoutSafeArea: requiresHdsLayoutSafeAreaAvoidance(ImmersiveLightArea.TITLE_BAR),
      enableComponentSafeArea: requiresHdsComponentSafeArea(ImmersiveLightArea.TITLE_BAR),
      style: buildImmersiveTitleBarStyle({ enableRefreshOffsetChange: false }),
      content: {
        title: {
          mainTitle: '静音的版块与标签'
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
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_gray'))
  }

  @Builder
  private Content() {
    if (this.loading || this.loadFailed) {
      Column() {
        LoadStateView({
          isLoading: this.loading,
          loadingText: '加载中…',
          message: this.message.length > 0 ? this.message : '加载失败，请重试',
          showRetry: this.loadFailed,
          emptyTitle: '暂无版块',
          onRetry: () => {
            this.load();
          }
        })
      }
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    } else {
      Scroll() {
        Column() {
          Blank()
            .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))

          Text('静音后不再收到该版块/标签的通知；帖子仍会出现在列表里。')
            .fontSize(12)
            .fontColor($r('app.color.text_faint'))
            .width('100%')
            .padding({ left: 20, right: 20, top: 4, bottom: 8 })

          // ===== 版块 =====
          Text('版块')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 20, right: 20, bottom: 6 })

          Column() {
            ForEach(this.categories, (category: TopicCategory) => {
              Row() {
                Column() {
                  Text(category.name)
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                  if (this.parentNameOf(category).length > 0) {
                    Text(this.parentNameOf(category))
                      .fontSize(11)
                      .fontColor($r('app.color.text_faint'))
                      .margin({ top: 1 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.isCategoryMuted(category.id) })
                  .enabled(this.savingCategoryId !== category.id)
                  .onChange((isOn: boolean) => {
                    this.toggleCategory(category, isOn);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor($r('app.color.card_bg'))
            }, (category: TopicCategory) => `c${category.id}`)
          }
          .width('100%')
          .borderRadius(12)
          .clip(true)
          .margin({ left: 12, right: 12 })

          // ===== 标签 =====
          Text('标签')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 20, right: 20, top: 18, bottom: 6 })

          Column() {
            if (this.mutedTags.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.mutedTags, (tag: string) => {
                  ChoiceChip({
                    label: tag,
                    removable: true,
                    compact: true,
                    onTap: () => {
                      this.setTagMuted(tag, false);
                    }
                  })
                }, (tag: string) => `t${tag}`)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 8 })
            } else {
              Text('还没有静音的标签')
                .fontSize(13)
                .fontColor($r('app.color.text_faint'))
                .width('100%')
                .padding({ left: 16, right: 16, top: 8 })
            }

            Row() {
              TextInput({ text: $$this.tagInput, placeholder: '输入标签名，静音它' })
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.surface_muted'))
                .borderRadius(10)
                .layoutWeight(1)
                .onSubmit(() => {
                  this.muteTagInput();
                })
              Button('静音')
                .height(36)
                .fontSize(14)
                .fontColor(Color.White)
                .backgroundColor($r('app.color.brand'))
                .borderRadius(18)
                .margin({ left: 8 })
                .enabled(!this.savingTag)
                .onClick(() => {
                  this.muteTagInput();
                })
            }
            .width('100%')
            .padding({ left: 12, right: 12, top: 10, bottom: 12 })
          }
          .width('100%')
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)
          .clip(true)
          .margin({ left: 12, right: 12 })

          Row()
            .height(24)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    }
  }
}
