import { NotificationEventBus, NotificationSnapshot } from '../../services/notification/NotificationEventBus';
import { SYS_BOTTOM_INSET_KEY } from '../../common/utils/ImmersiveWindow';

// ===== 飞书/微信式底部导航栏 =====
// 4 个一级 tab 等分:首页 / 论坛 / 通知 / 我的。选中深色高亮、未选中灰色,
// 顶部 1vp 分隔线、底部跟随 HOME 指示条安全区。通知 tab 订阅事件总线显示红点角标。
// 悬浮在 RootTabPage 根 Stack 底部,选中态由宿主单向驱动(@Prop current),
// 仅四个一级 tab 在栈顶时由宿主挂载。

const TAB_ICON_SIZE: number = 24;
const TAB_LABEL_SIZE: number = 11;
// 内容条高度(不含系统底部安全区)。
const TAB_BAR_HEIGHT: number = 52;
const TAB_ANIM_MS: number = 200;
// 图标字号内的留白,容纳红点角标不溢出。
const TAB_ICON_BOX: number = 32;

export enum BottomTabId {
  HOME = 0,
  FORUMS = 1,
  NOTIFICATIONS = 2,
  PROFILE = 3
}

const TAB_LABELS: string[] = ['首页', '论坛', '通知', '我的'];

@Component
export struct BottomTabBar {
  @StorageProp(SYS_BOTTOM_INSET_KEY) private sysBottomInset: number = 0;
  // 选中 tab:父组件驱动。点击通过 onSelect 上抛,由父组件改状态回灌。
  @Prop current: number = BottomTabId.HOME;
  onSelect: (tab: BottomTabId) => void = () => {};
  @State private unread: number = 0;
  private unsubscribe?: () => void = undefined;

  aboutToAppear(): void {
    this.unread = NotificationEventBus.current().unread;
    this.unsubscribe = NotificationEventBus.subscribe((snapshot: NotificationSnapshot) => {
      this.unread = snapshot.unread;
    });
  }

  aboutToDisappear(): void {
    if (this.unsubscribe) {
      this.unsubscribe();
      this.unsubscribe = undefined;
    }
  }

  // 选中/未选中图标:方法内 switch 返回字面量资源,规避顶层 $r 在 ArkTS strict 下的限制。
  private onSymbol(index: number): Resource {
    switch (index) {
      case BottomTabId.HOME: return $r('sys.symbol.house');
      case BottomTabId.FORUMS: return $r('sys.symbol.forum');
      case BottomTabId.NOTIFICATIONS: return $r('sys.symbol.bell_fill');
      case BottomTabId.PROFILE: return $r('sys.symbol.person');
      default: return $r('sys.symbol.house');
    }
  }

  private offSymbol(index: number): Resource {
    switch (index) {
      case BottomTabId.HOME: return $r('sys.symbol.house');
      case BottomTabId.FORUMS: return $r('sys.symbol.forum');
      case BottomTabId.NOTIFICATIONS: return $r('sys.symbol.bell');
      case BottomTabId.PROFILE: return $r('sys.symbol.person');
      default: return $r('sys.symbol.house');
    }
  }

  build() {
    Column() {
      Row() {
        ForEach(TAB_LABELS, (label: string, index: number) => {
          this.TabItem(label, index)
        }, (label: string, index: number) => `${label}_${index}`)
      }
      .width('100%')
      .height(TAB_BAR_HEIGHT)
      .alignItems(VerticalAlign.Center)

      // 底部 HOME 指示条安全区(手势条高低由系统安全区决定)。
      Row() {}
        .width('100%')
        .height(this.sysBottomInset)
    }
    .width('100%')
    .border({ width: { top: 0.5 }, color: $r('app.color.tab_bar_sep') })
    .backgroundColor($r('app.color.tab_bar_bg'))
  }

  @Builder
  private TabItem(label: string, index: number) {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        SymbolGlyph(index === this.current ? this.onSymbol(index) : this.offSymbol(index))
          .fontSize(TAB_ICON_SIZE)
          .fontColor([index === this.current ? $r('app.color.tab_fg_on') : $r('app.color.tab_fg_off')])
          .renderingStrategy(SymbolRenderingStrategy.SINGLE)
        // 未读红点:仅通知 tab 且未读 >0 时显示(简洁飞书风,数字在顶部铃铛与通知页内)。
        if (index === BottomTabId.NOTIFICATIONS && this.unread > 0) {
          Circle()
            .width(7)
            .height(7)
            .fill($r('app.color.tab_badge'))
            .margin({ top: 1, right: -1 })
        }
      }
      .width(TAB_ICON_BOX)
      .height(TAB_ICON_BOX)

      Text(label)
        .fontSize(TAB_LABEL_SIZE)
        .fontColor(index === this.current ? $r('app.color.tab_fg_on') : $r('app.color.tab_fg_off'))
        .fontWeight(index === this.current ? FontWeight.Medium : FontWeight.Regular)
    }
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .height('100%')
    .onClick(() => {
      if (index === this.current) {
        // 点当前 tab(非首页):微信/飞书行为,再点一次回首页顶部。
        if (index !== BottomTabId.HOME) {
          this.onSelect(BottomTabId.HOME);
        }
        return;
      }
      this.onSelect(index as BottomTabId);
    })
  }
}
