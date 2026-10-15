import { common } from '@kit.AbilityKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { DownloadService } from '../../services/content/DownloadService';
import { FileLogger } from '../../services/logging/FileLogger';
import { Log } from '../../services/logging/Log';
import { NetworkSnapshotService } from '../../services/diagnostics/NetworkSnapshotService';
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

const LOG_TAG: string = '[ArkDO][Diag]';

// 诊断日志子页:从设置页拆出。导出(带大小)、详细日志开关、清空,用于用户脱机跑一天后导出日志分析。
@Component
export struct DiagnosticsSettingsPage {
  // 窗口常驻全屏布局:内容层自行避让状态栏(背景层已天然铺满整屏,含状态栏条)。
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  onBack: () => void = () => {};
  // 日志工具:大小标签实时展示,详细日志开关持久化,导出时防重复点击。
  @State private logSizeLabel: string = '';
  @State private verboseLog: boolean = false;
  @State private isExportingLog: boolean = false;
  // 网络快照(一键诊断):采集 DoH/直连/登录态 + 最近关键日志,弹层展示并可复制。
  @State private snapshotText: string = '';
  @State private snapshotVisible: boolean = false;
  @State private snapshotCollecting: boolean = false;
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.verboseLog = FileLogger.isVerbose();
    this.refreshLogSize();
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
      this.ScrollableContent()
      this.TitleBarOverlay()
    }
    .bindSheet($$this.snapshotVisible, this.SnapshotSheet, {
      height: SheetSize.LARGE,
      dragBar: true,
      showClose: true
    })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_gray'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // ==================== Builder ====================

  @Builder
  private ScrollableContent() {
    Scroll(this.scroller) {
      Column() {
        Blank()
          .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))

        this.LogGroup()

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
          mainTitle: '诊断日志'
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

  @Builder
  private LogGroup() {
    Column() {
      Row() {
        SymbolGlyph($r('sys.symbol.envelope'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
        Text('导出日志')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
          .margin({ left: 14 })
        if (this.isExportingLog) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.ld_accent'))
            .margin({ right: 6 })
        } else if (this.logSizeLabel.length > 0) {
          Text(this.logSizeLabel)
            .fontSize(13)
            .fontColor($r('app.color.text_faint'))
            .margin({ right: 6 })
        }
        this.ChevronIcon()
      }
      .width('100%')
      .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 14, bottom: 14 })
      .onClick(() => {
        this.exportLog();
      })

      this.HairlineInset()

      // 一键网络快照:网络类问题(刷不出来/掉登录/过不了盾)第一手证据。
      Row() {
        SymbolGlyph($r('sys.symbol.wifi'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
        Column() {
          Text('网络快照')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('采集 DoH/直连实测、登录态与最近关键日志')
            .fontSize(12)
            .fontColor($r('app.color.text_faint'))
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .margin({ left: 14 })
        .alignItems(HorizontalAlign.Start)
        if (this.snapshotCollecting) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.ld_accent'))
            .margin({ right: 6 })
        }
        this.ChevronIcon()
      }
      .width('100%')
      .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 14, bottom: 14 })
      .onClick(() => {
        this.collectNetworkSnapshot();
      })

      this.HairlineInset()

      Row() {
        SymbolGlyph($r('sys.symbol.info_circle'))
          .fontSize(20)
          .fontColor([$r('app.color.text_secondary')])
        Column() {
          Text('详细日志')
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('完整记录响应内容，排查时开启')
            .fontSize(12)
            .fontColor($r('app.color.text_faint'))
            .width('100%')
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .margin({ left: 14 })
        .alignItems(HorizontalAlign.Start)

        Toggle({ type: ToggleType.Switch, isOn: this.verboseLog })
          .selectedColor($r('app.color.ld_accent'))
          .onChange((isOn: boolean) => {
            this.setVerboseLog(isOn);
          })
      }
      .width('100%')
      .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 12, bottom: 12 })

      this.HairlineInset()

      Row() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(20)
          .fontColor([$r('app.color.ld_danger')])
        Text('清空日志')
          .fontSize(15)
          .fontColor($r('app.color.ld_danger'))
          .layoutWeight(1)
          .margin({ left: 14 })
      }
      .width('100%')
      .padding({ left: CARD_PADDING, right: CARD_PADDING, top: 14, bottom: 14 })
      .onClick(() => {
        this.confirmClearLog();
      })
    }
    .cardStyle()
  }

  // 「网络快照」弹层:现场太大,给整屏滚动 + 一键复制。
  @Builder
  private SnapshotSheet() {
    Column() {
      Row() {
        Text('网络快照')
          .fontSize(17)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text('复制')
          .fontSize(15)
          .fontColor($r('app.color.brand'))
          .padding({ left: 12, right: 4, top: 4, bottom: 4 })
          .onClick(() => {
            this.copySnapshot();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4, bottom: 8 })

      Scroll() {
        Text(this.snapshotText)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Start)
          .copyOption(CopyOptions.LocalDevice)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.TopStart)
      .padding({ left: 16, right: 16, bottom: 16 })
      .scrollBar(BarState.Auto)
    }
    .width('100%')
    .height('100%')
  }

  private async collectNetworkSnapshot(): Promise<void> {
    if (this.snapshotCollecting) {
      return;
    }
    this.snapshotCollecting = true;
    try {
      const context: common.Context = this.getUIContext().getHostContext() as common.Context;
      this.snapshotText = await NetworkSnapshotService.collect(context);
      this.snapshotVisible = true;
    } catch (error) {
      Log.i(`${LOG_TAG} network snapshot failed: ${JSON.stringify(error)}`);
      this.showToast('网络快照采集失败');
    } finally {
      this.snapshotCollecting = false;
    }
  }

  private copySnapshot(): void {
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.snapshotText);
      pasteboard.getSystemPasteboard().setDataSync(data);
      this.showToast('网络快照已复制');
    } catch (error) {
      this.showToast('复制失败');
    }
  }

  @Builder
  private HairlineInset() {
    Divider()
      .strokeWidth(0.5)
      .color($r('app.color.border'))
      .margin({ left: CARD_PADDING, right: CARD_PADDING })
  }

  @Builder
  private ChevronIcon() {
    SymbolGlyph($r('sys.symbol.chevron_right'))
      .fontSize(18)
      .fontColor([$r('app.color.text_faint')])
  }

  // ==================== 诊断日志 ====================

  private refreshLogSize(): void {
    this.logSizeLabel = this.formatBytes(FileLogger.getTotalSizeBytes());
  }

  private formatBytes(bytes: number): string {
    if (bytes <= 0) {
      return '空';
    }
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private exportLog(): void {
    if (this.isExportingLog) {
      return;
    }
    this.isExportingLog = true;
    // 合并落盘 + 拉起系统分享面板(复用附件分享链路),用户可选邮件/IM 发出。
    const exportPath: string = FileLogger.exportToFile();
    this.isExportingLog = false;
    this.refreshLogSize();
    if (exportPath.length === 0) {
      this.showToast('日志导出失败,请稍后重试');
      return;
    }
    DownloadService.openWithSystem(this.getUIContext().getHostContext() as common.UIAbilityContext, exportPath);
  }

  private setVerboseLog(isOn: boolean): void {
    this.verboseLog = isOn;
    FileLogger.setVerbose(this.getUIContext().getHostContext() as common.Context, isOn);
  }

  private confirmClearLog(): void {
    this.getUIContext().showAlertDialog({
      title: '清空日志',
      message: '确定要清空本机所有日志吗?此操作不可恢复。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: $r('app.color.ld_danger'),
        action: () => {
          FileLogger.clear();
          this.refreshLogSize();
          this.showToast('日志已清空');
        }
      }
    });
  }

  private showToast(message: string): void {
    promptToast(this.getUIContext(), message);
  }
}
