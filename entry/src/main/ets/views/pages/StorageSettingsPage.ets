import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { common } from '@kit.AbilityKit';
import { DownloadFile, StorageCleanupService, StorageUsage } from '../../services/storage/StorageCleanupService';
import { showToast, TOAST_SHORT_MS } from '../../common/utils/Toast';
import { SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';

/**
 * 存储与缓存:图片缓存 + 附件下载目录。
 *
 * 只清「可重建」的东西:图片缓存随时能重新取,下载目录是用户点过下载留下的副本。
 * 登录态 / 草稿 / 设置一概不碰 —— 页面上也写明这一点,免得用户以为「清缓存」会把登录清掉。
 *
 * 离线阅读不在这里:那需要把主题正文持久化并处理失效/更新,是另一套数据层,
 * 不做成「顺手加个开关」的样子。
 */
@Component
export struct StorageSettingsPage {
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  onBack: () => void = () => {};

  @State private usage: StorageUsage = {
    imageEntries: 0, imageBytes: 0, imageMaxBytes: 0, downloadFiles: [], downloadBytes: 0
  };

  aboutToAppear(): void {
    this.refresh();
  }

  private context(): common.Context {
    return this.getUIContext().getHostContext() as common.Context;
  }

  private refresh(): void {
    this.usage = StorageCleanupService.usage(this.context());
  }

  private clearImages(): void {
    const freed: number = StorageCleanupService.clearImageCaches();
    this.refresh();
    showToast(this.getUIContext(), `已清理 ${StorageCleanupService.formatBytes(freed)}`, TOAST_SHORT_MS);
  }

  private clearDownloads(): void {
    const freed: number = StorageCleanupService.clearDownloads(this.context());
    this.refresh();
    showToast(this.getUIContext(), `已删除 ${StorageCleanupService.formatBytes(freed)}`, TOAST_SHORT_MS);
  }

  private deleteDownload(file: DownloadFile): void {
    if (StorageCleanupService.deleteDownload(file)) {
      this.refresh();
      showToast(this.getUIContext(), '已删除', TOAST_SHORT_MS);
      return;
    }
    showToast(this.getUIContext(), '删除失败，请稍后重试', TOAST_SHORT_MS);
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
          mainTitle: '存储与缓存'
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
    Scroll() {
      Column() {
        Blank()
          .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))

        Text('这里只清理可重建的内容：图片缓存与已下载的附件。登录状态、草稿与设置不会被清除。')
          .fontSize(12)
          .fontColor($r('app.color.text_faint'))
          .width('100%')
          .padding({ left: 20, right: 20, top: 4, bottom: 8 })

        // ===== 图片缓存 =====
        Text('图片缓存')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 20, right: 20, bottom: 6 })

        Column() {
          Row() {
            Column() {
              Text(`${this.usage.imageEntries} 张已解码图片`)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text(`${StorageCleanupService.formatBytes(this.usage.imageBytes)} / 上限 ` +
                `${StorageCleanupService.formatBytes(this.usage.imageMaxBytes)}`)
                .fontSize(12)
                .fontColor($r('app.color.text_faint'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('清理')
              .height(32)
              .fontSize(13)
              .fontColor($r('app.color.brand'))
              .backgroundColor($r('app.color.info_soft_bg'))
              .borderRadius(16)
              .padding({ left: 16, right: 16 })
              .enabled(this.usage.imageEntries > 0)
              .onClick(() => {
                this.clearImages();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        .width('100%')
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(12)
        .clip(true)
        .margin({ left: 12, right: 12 })

        // ===== 下载文件 =====
        Row() {
          Text('下载的附件')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1)
          if (this.usage.downloadFiles.length > 0) {
            Text(`全部删除（${StorageCleanupService.formatBytes(this.usage.downloadBytes)}）`)
              .fontSize(12)
              .fontColor($r('app.color.warning'))
              .onClick(() => {
                this.clearDownloads();
              })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 18, bottom: 6 })

        Column() {
          if (this.usage.downloadFiles.length === 0) {
            Text('还没有下载过附件')
              .fontSize(13)
              .fontColor($r('app.color.text_faint'))
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          } else {
            ForEach(this.usage.downloadFiles, (file: DownloadFile) => {
              Row() {
                Column() {
                  Text(file.name)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(StorageCleanupService.formatBytes(file.size))
                    .fontSize(11)
                    .fontColor($r('app.color.text_faint'))
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text('删除')
                  .fontSize(13)
                  .fontColor($r('app.color.warning'))
                  .padding({ left: 12 })
                  .onClick(() => {
                    this.deleteDownload(file);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
            }, (file: DownloadFile) => file.path)
          }
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
