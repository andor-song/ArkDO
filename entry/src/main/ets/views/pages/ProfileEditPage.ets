import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { ProfileEditableData, UserProfileDetail } from '../../models/UserProfile';
import { UserProfileService } from '../../services/user/UserProfileService';
import { UserProfileCache } from '../../services/user/UserProfileCache';
import { ArkWebNetworkBridge } from '../../services/network/ArkWebNetworkBridge';
import { NetworkResult } from '../../services/network/NetworkTypes';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { showToast as promptToast } from '../../common/utils/Toast';
import { CARD_GAP, CARD_PADDING, CARD_RADIUS, PAGE_MARGIN } from '../../common/theme/Metrics';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';

const LOG_TAG: string = '[ArkDO][ProfileEdit]';

/**
 * 个人资料编辑页:登录本人专用。字段 = Discourse 资料设置(姓名/头衔/网站/所在地/简介)。
 * 预填来自 /u/{username}.json 的 user + user.user_profile;保存走 PUT /u/{username}.json
 * (user[name] 等 form 字段),成功后刷新缓存并回退,名字改动由 RootTabPage 重查会话同步到全局。
 */
@Component
export struct ProfileEditPage {
  // 窗口常驻全屏布局:内容层自行避让状态栏(背景层已天然铺满整屏,含状态栏条)。
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  bridge: ArkWebNetworkBridge = new ArkWebNetworkBridge();
  username: string = '';
  onBack: () => void = () => {};
  // 保存成功后由 RootTabPage 接住:刷新会话/缓存,再 pop。
  onSaved: () => void = () => {};

  @State private name: string = '';
  @State private title: string = '';
  @State private website: string = '';
  @State private location: string = '';
  @State private bioRaw: string = '';
  @State private loading: boolean = true;
  @State private loadFailed: boolean = false;
  @State private saving: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.loadEditable();
  }

  private async loadEditable(): Promise<void> {
    this.loading = true;
    this.loadFailed = false;
    const service: UserProfileService = new UserProfileService(this.bridge);
    const result: NetworkResult<ProfileEditableData> = await service.getProfileEditable(this.username);
    this.loading = false;
    if (result.success && result.data) {
      const data: ProfileEditableData = result.data;
      this.name = data.name;
      this.title = data.title;
      this.website = data.website;
      this.location = data.location;
      this.bioRaw = data.bioRaw;
      Log.i(`${LOG_TAG} editable loaded username=${data.username}`);
    } else {
      this.loadFailed = true;
      const reason: string = result.error ? result.error.message : '加载失败';
      promptToast(this.getUIContext(), reason, 2500);
      Log.i(`${LOG_TAG} editable load failed status=${result.statusCode}`);
    }
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    const fields: ProfileEditableData = {
      name: this.name.trim(),
      title: this.title.trim(),
      website: this.website.trim(),
      location: this.location.trim(),
      bioRaw: this.bioRaw.trim(),
      username: this.username
    };
    const service: UserProfileService = new UserProfileService(this.bridge);
    const result: NetworkResult<boolean> = await service.updateProfile(this.username, fields);
    this.saving = false;
    if (result.success && result.data) {
      // 服务端返回的详情刷新缓存:回退时「我的」页/他人主页能看到新简介与名字。
      const fresh: NetworkResult<UserProfileDetail> =
        await service.getProfileDetail(this.username);
      if (fresh.success && fresh.data) {
        UserProfileCache.setDetail(this.username, fresh.data);
      }
      promptToast(this.getUIContext(), '资料已保存', 1500);
      this.onSaved();
    } else {
      const reason: string = result.error ? result.error.message : '保存失败，请稍后重试。';
      promptToast(this.getUIContext(), reason, 2500);
      Log.i(`${LOG_TAG} profile update failed status=${result.statusCode}`);
    }
  }

  @Styles
  cardStyle() {
    .width('100%')
    .backgroundColor($r('app.color.surface_card'))
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.ScrollableContent()
      this.TitleBarOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_gray'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  private ScrollableContent() {
    Scroll(this.scroller) {
      Column() {
        Blank()
          .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))

        if (this.loading) {
          Row() {
            LoadingProgress()
              .width(18)
              .height(18)
              .color($r('app.color.ld_accent'))
            Text('正在加载资料…')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 60, bottom: 60 })
        } else if (this.loadFailed) {
          Column() {
            Text('资料加载失败')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            Button('重试', { type: ButtonType.Normal })
              .fontSize(14)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.surface_muted'))
              .borderRadius(18)
              .margin({ top: 12 })
              .onClick(() => {
                this.loadEditable();
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
          .padding({ top: 60, bottom: 60 })
        } else {
          this.FieldGroup()
          this.ActionRow()
        }

        Row()
          .width('100%')
          .height(40)
      }
      .width('100%')
      .padding({ left: PAGE_MARGIN, right: PAGE_MARGIN })
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // 字段卡片:每行 label + 输入框,行间发丝线。
  @Builder
  private FieldGroup() {
    Column() {
      this.FieldRow('姓名', '昵称/显示名', this.name, (value: string) => { this.name = value; })
      this.HairlineInset()
      this.FieldRow('头衔', '如「活跃用户」', this.title, (value: string) => { this.title = value; })
      this.HairlineInset()
      this.FieldRow('网站', 'https://…', this.website, (value: string) => { this.website = value; })
      this.HairlineInset()
      this.FieldRow('所在地', '城市/地区', this.location, (value: string) => { this.location = value; })
      this.HairlineInset()

      // 简介:多行文本域。
      Row() {
        Text('简介')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .width(64)
        TextArea({ text: $$this.bioRaw, placeholder: '一句话介绍自己(支持 Markdown)…' })
          .width('100%')
          .height(120)
          .backgroundColor($r('app.color.surface_muted'))
          .borderRadius(10)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_tertiary'))
          .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 12, bottom: 12 })
    }
    .cardStyle()
  }

  @Builder
  private FieldRow(label: string, placeholder: string, value: string, onChange: (value: string) => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .width(64)
      TextInput({ text: value, placeholder: placeholder })
        .layoutWeight(1)
        .backgroundColor(Color.Transparent)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .padding({ left: 0, right: 8, top: 10, bottom: 10 })
        .onChange((newValue: string) => {
          onChange(newValue);
        })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 6, bottom: 6 })
  }

  @Builder
  private ActionRow() {
    Button(this.saving ? '保存中…' : '保存资料', { type: ButtonType.Normal })
      .width('100%')
      .height(48)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor(Color.White)
      .backgroundColor($r('app.color.brand'))
      .borderRadius(24)
      .margin({ top: CARD_GAP + 4 })
      .enabled(!this.saving)
      .onClick(() => {
        this.save();
      })
  }

  @Builder
  private TitleBarOverlay() {
    HdsNavigation() {
      Column()
        .width('100%')
        .height('100%')
    }
    .titleBar({
      avoidLayoutSafeArea: requiresHdsLayoutSafeAreaAvoidance(ImmersiveLightArea.TITLE_BAR),
      enableComponentSafeArea: requiresHdsComponentSafeArea(ImmersiveLightArea.TITLE_BAR),
      style: buildImmersiveTitleBarStyle(),
      content: {
        title: {
          mainTitle: '编辑资料'
        },
        backIcon: {
          icon: $r('sys.symbol.chevron_left'),
          label: '返回',
          action: () => {
            this.onBack();
          }
        },
        menu: {
          value: [{
            content: {
              icon: $r('sys.symbol.checkmark'),
              label: '保存',
              isEnabled: !this.saving,
              action: () => {
                this.save();
              }
            }
          }]
        }
      }
    })
    .bindToScrollable([this.scroller])
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  private HairlineInset() {
    Divider()
      .strokeWidth(0.5)
      .color($r('app.color.border'))
      .padding({ left: CARD_PADDING, right: CARD_PADDING })
  }
}
