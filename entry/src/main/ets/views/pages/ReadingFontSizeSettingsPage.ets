import { common } from '@kit.AbilityKit';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { CARD_GAP, CARD_PADDING, CARD_RADIUS, PAGE_MARGIN } from '../../common/theme/Metrics';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';
import {
  READING_FONT_SIZE_MAX,
  READING_FONT_SIZE_MIN,
  READING_LINE_HEIGHT_RATIO_MAX,
  READING_LINE_HEIGHT_RATIO_MIN,
  READING_LINE_HEIGHT_RATIO_STEP,
  ReadingFontSizePrefs,
  ReadingFontSizeStyle
} from '../../common/theme/ReadingFontSizePrefs';
import { PostRichContent } from '../components/PostRichContent';

/**
 * 阅读字号设置页:调帖子正文的字号与行高,顶部固定预览区实时反映。
 *
 * 四个调用 PostRichContent 的入口(帖子详情 / 楼层回复折叠 / 首页流 / 采纳答案面板)共用
 * 同一组件,故这套设置对四处同时生效——同一个正文渲染器维持同一套视觉语言。
 *
 * 预览用的就是 PostRichContent 本体而不是另画一份仿制品:所见即所得,且日后改正文排版不会
 * 出现「预览和真实正文长得不一样」这种最难发现的偏差。示例稿覆盖正文里最常见的元素:
 * 段落、小标题、列表,调任一项都能立刻看出影响面。
 *
 * 写盘时机:滑块 onChange 每帧都来,拖动中只更新 AppStorage(预览与真实正文即时跟手),
 * 松手(End/Click)才落盘,避免每帧 store.flush()。
 */
@Component
export struct ReadingFontSizeSettingsPage {
  // 窗口常驻全屏布局:内容层自行避让状态栏(背景层已天然铺满整屏,含状态栏条)。
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  onBack: () => void = () => {};
  // 两个可调值的页内镜像:滑块要双向绑定,故各存一份 @State,变更后同步进 prefs。
  @State private bodyFontSize: number = 15;
  @State private lineHeightRatio: number = 1.47;
  // 预览正文的示例稿(简单 Markdown 风 cooking):段落 + 小标题 + 列表,覆盖正文主要元素。
  // 经 CookedHtmlParser 的缓存链路,与真实楼层正文同一条渲染管线。
  private previewHtml: string = '<p>这是一段示例正文。调整下方的「正文字号」与「行高」滑块，预览会即时变化。</p>' +
    '<h2>小标题跟着正文比例缩放</h2>' +
    '<p>正文滑块改动的是整套排版的基准：标题、行内代码、引用角标都按同一个比例联动，不会出现「正文放大了标题还挤成一坨」的失衡。</p>' +
    '<ul><li>列表项的行高与正文对齐</li><li>每一项都可以多行文字</li></ul>' +
    '<p>默认值与改造前的硬编码完全一致，没动过设置的用户升级后阅读体验分毫不变。</p>';
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const style: ReadingFontSizeStyle = ReadingFontSizePrefs.current();
    this.bodyFontSize = style.bodyFontSize;
    this.lineHeightRatio = style.lineHeightRatio;
  }

  // 宿主 Context 收口。getContext(this) 已废弃,统一从 UIContext 取,免得每个调用点各写一遍 cast。
  private hostContext(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  // 卡片分组容器:无描边,靠灰底衬托。
  @Styles
  cardStyle() {
    .width('100%')
    .backgroundColor($r('app.color.surface_card'))
    .borderRadius(CARD_RADIUS)
    .margin({ top: CARD_GAP })
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Blank()
          .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))

        // 预览区固定在顶部不随控件滚走:调滑块时眼睛不必在页面上下找效果。
        this.PreviewCard()

        this.ControlsScroll()
      }
      .width('100%')
      .height('100%')
      .padding({ left: PAGE_MARGIN, right: PAGE_MARGIN })
      .alignItems(HorizontalAlign.Start)

      this.TitleBarOverlay()
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_gray'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ==================== Builder:预览 ====================

  @Builder
  private PreviewCard() {
    Column() {
      PostRichContent({
        cookedHtml: this.previewHtml,
        onOpenLink: (url: string) => {
        },
        onTrackLink: (url: string) => {
        }
      })
      .width('100%')
    }
    .cardStyle()
    .clip(true)
    .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 8, bottom: 8 })
    .margin({ top: 0 })
  }

  // ==================== Builder:控件 ====================

  @Builder
  private ControlsScroll() {
    Scroll(this.scroller) {
      Column() {
        Column() {
          this.SliderCell({
            label: '正文字号',
            valueLabel: `${this.bodyFontSize}`,
            value: this.bodyFontSize,
            min: READING_FONT_SIZE_MIN,
            max: READING_FONT_SIZE_MAX,
            step: 1,
            onSliderChange: (value: number, done: boolean) => {
              this.bodyFontSize = ReadingFontSizePrefs.setBodyFontSize(value);
              this.persistIfDone(done);
            }
          })
          this.HairlineInset()
          this.SliderCell({
            label: '行高',
            valueLabel: this.lineHeightRatio.toFixed(2),
            value: this.lineHeightRatio,
            min: READING_LINE_HEIGHT_RATIO_MIN,
            max: READING_LINE_HEIGHT_RATIO_MAX,
            step: READING_LINE_HEIGHT_RATIO_STEP,
            onSliderChange: (value: number, done: boolean) => {
              this.lineHeightRatio = ReadingFontSizePrefs.setLineHeightRatio(value);
              this.persistIfDone(done);
            }
          })
        }
        .cardStyle()

        Text('设置对帖子详情、首页流、采纳答案面板同时生效。')
          .fontSize(12)
          .fontColor($r('app.color.text_faint'))
          .width('100%')
          .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 10 })

        this.ResetButton()

        Row()
          .width('100%')
          .height(40)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .align(Alignment.Top)
  }

  // 滑块行:标题 + 当前值在上,滑块与两端极值在下。两端标出极值,让人一眼知道还能调多少。
  // 入参必须是单参数对象且调用点直接写对象字面量:@Builder 只有这种形态是按引用传递,
  // 否则拖动时右上角的数值不刷新(与列表样式设置页同款陷阱,勿改)。
  @Builder
  private SliderCell(params: SliderCellParams) {
    Column() {
      Row() {
        Text(params.label)
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(params.valueLabel)
          .fontSize(13)
          .fontColor($r('app.color.text_faint'))
      }
      .width('100%')

      Row() {
        Text(`${params.min}`)
          .fontSize(11)
          .fontColor($r('app.color.text_faint'))
        Slider({
          value: params.value,
          min: params.min,
          max: params.max,
          step: params.step,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor($r('app.color.ld_accent'))
          .trackThickness(4)
          .onChange((sliderValue: number, mode: SliderChangeMode) => {
            params.onSliderChange(sliderValue,
              mode === SliderChangeMode.End || mode === SliderChangeMode.Click);
          })
        Text(`${params.max}`)
          .fontSize(11)
          .fontColor($r('app.color.text_faint'))
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 12, bottom: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  private ResetButton() {
    Button('恢复默认')
      .fontSize(15)
      .fontColor($r('app.color.text_primary'))
      .backgroundColor($r('app.color.surface_card'))
      .width('100%')
      .height(48)
      .borderRadius(CARD_RADIUS)
      .margin({ top: CARD_GAP })
      .onClick(() => {
        const style: ReadingFontSizeStyle = ReadingFontSizePrefs.resetDefaults(this.hostContext());
        this.bodyFontSize = style.bodyFontSize;
        this.lineHeightRatio = style.lineHeightRatio;
      })
  }

  @Builder
  private HairlineInset() {
    Divider()
      .strokeWidth(0.5)
      .color($r('app.color.border'))
      .margin({ left: CARD_PADDING, right: CARD_PADDING })
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
          mainTitle: '阅读字号'
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
    .backgroundColor(Color.Transparent)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  // ==================== 逻辑 ====================

  private persistIfDone(done: boolean): void {
    if (done) {
      ReadingFontSizePrefs.flush(this.hostContext());
    }
  }
}

// 滑块行的入参。必须打成一个对象、且在调用点直接写成对象字面量:@Builder 只有「单参数 +
// 对象字面量」这一种形态是按引用传递,其余(含多参数)都按值传递,参数变了不会刷新 Builder 内部——
// 那样拖动时右上角的数值会僵在原地,点「恢复默认」滑块也不会归位。
interface SliderCellParams {
  label: string;
  valueLabel: string;
  value: number;
  min: number;
  max: number;
  step: number;
  // done=true 表示这次是松手或点击定位,而非拖动途中的连续回调,只有它为真才落盘。
  onSliderChange: (value: number, done: boolean) => void;
}
