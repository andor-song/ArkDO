// 前摄挖孔处的未读消息胶囊:登录且有未读时,在挖孔正下方浮一条磨砂小胶囊,
// 点按直达通知页。数据源 = NotificationEventBus(轮询/实时通道/会话检查都会发)。
//
// 定位:以 ImmersiveWindow 同步的 TYPE_CUTOUT 包围盒为准——胶囊中心与挖孔水平中心对齐,
// 顶边贴着孔的下缘(不遮挡镜头,视觉上是「从孔里垂下来的一条提醒」)。无挖孔设备/模拟器
// 退化为状态栏下缘水平居中,保证功能可测。
import { NotificationEventBus, NotificationSnapshot } from '../../services/notification/NotificationEventBus';
import {
  CUTOUT_HEIGHT_INSET_KEY,
  CUTOUT_LEFT_INSET_KEY,
  CUTOUT_TOP_INSET_KEY,
  CUTOUT_WIDTH_INSET_KEY,
  SYS_TOP_INSET_KEY
} from '../../common/utils/ImmersiveWindow';
import { SHADOW_SOFT } from '../../common/theme/Palette';
import { Log } from '../../services/logging/Log';

const LOG_TAG: string = '[ArkDO][CutoutCapsule]';
// 胶囊顶边到挖孔下缘的空当(vp)。太小会贴住镜头,太大不像是挖孔处的提醒。
const CUTOUT_GAP_VP: number = 3;
// 无挖孔时的退化位置:状态栏下缘再往下让一点。
const NO_CUTOUT_FALLBACK_GAP_VP: number = 4;

@Component
export struct MessageCutoutCapsule {
  // 点胶囊跳通知页(由宿主 RootTabPage 注入,复用铃铛那条导航)。
  onOpen: () => void = () => {};
  @StorageProp(CUTOUT_LEFT_INSET_KEY) private cutoutLeftVp: number = 0;
  @StorageProp(CUTOUT_TOP_INSET_KEY) private cutoutTopVp: number = 0;
  @StorageProp(CUTOUT_WIDTH_INSET_KEY) private cutoutWidthVp: number = 0;
  @StorageProp(CUTOUT_HEIGHT_INSET_KEY) private cutoutHeightVp: number = 0;
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  @State private unread: number = 0;
  @State private highPriority: number = 0;
  private unsubscribeNotifications?: () => void = undefined;
  // 容器实际宽度(vp):无挖孔退化居中要用。onAreaChange 的宽度是 px,手动除密度。
  private containerWidthPx: number = 0;

  aboutToAppear(): void {
    this.unread = NotificationEventBus.current().unread;
    this.highPriority = NotificationEventBus.current().highPriority;
    this.unsubscribeNotifications = NotificationEventBus.subscribe((snapshot: NotificationSnapshot) => {
      this.unread = snapshot.unread;
      this.highPriority = snapshot.highPriority;
    });
    Log.i(`${LOG_TAG} appear unread=${this.unread} high=${this.highPriority}`);
  }

  aboutToDisappear(): void {
    if (this.unsubscribeNotifications) {
      this.unsubscribeNotifications();
      this.unsubscribeNotifications = undefined;
    }
  }

  private hasCutout(): boolean {
    return this.cutoutWidthVp > 0 && this.cutoutHeightVp > 0;
  }

  // 胶囊左缘锚点(经 markAnchor x:'50%' 后即「胶囊中心」落点)。
  private capsuleCenterX(): number {
    if (this.hasCutout()) {
      return this.cutoutLeftVp + this.cutoutWidthVp / 2;
    }
    // 无挖孔退化:水平居中。容器占满窗宽,onAreaChange 给的是物理像素,px2vp 换回 vp。
    return this.containerWidthPx === 0 ? 0 : px2vp(this.containerWidthPx) / 2;
  }

  private capsuleTop(): number {
    if (this.hasCutout()) {
      return this.cutoutTopVp + this.cutoutHeightVp + CUTOUT_GAP_VP;
    }
    return this.sysTopInset + NO_CUTOUT_FALLBACK_GAP_VP;
  }

  build() {
    // 满屏透明容器:只拦截胶囊本身的触摸,其余放行给底层页面/导航。
    Stack() {
      if (this.unread > 0 || this.highPriority > 0) {
        Row({ space: 5 }) {
          SymbolGlyph($r('sys.symbol.bell_fill'))
            .fontSize(13)
            .fontColor($r('app.color.brand'))
          Text(this.formatCount())
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
        }
        .padding({ left: 11, right: 11, top: 5, bottom: 5 })
        // 与详情页「N 条新回复」/悬浮回复按钮同一套磨砂:强磨砂 + 通透。
        .backgroundEffect({
          radius: 18,
          color: $r('app.color.hds_floating_action_bg'),
          saturation: 1.2
        })
        .borderRadius(15)
        .shadow({ radius: 8, color: SHADOW_SOFT, offsetX: 0, offsetY: 2 })
        .position({ x: this.capsuleCenterX(), y: this.capsuleTop() })
        // 定位参考点取自身中心:position 的 x 直接就是「挖孔中心横坐标」,不必预知胶囊宽度。
        .markAnchor({ x: '50%', y: 0 })
        .onClick(() => {
          Log.i(`${LOG_TAG} open notifications unread=${this.unread} high=${this.highPriority}`);
          this.onOpen();
        })
        .transition(TransitionEffect.OPACITY.animation({ duration: 150, curve: Curve.EaseOut }))
      }
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.Transparent)
    .onAreaChange((_oldValue: Area, newValue: Area) => {
      const widthPx: number = newValue.width as number;
      if (widthPx > 0) {
        this.containerWidthPx = widthPx;
      }
    })
  }

  private formatCount(): string {
    const total: number = this.unread + this.highPriority;
    return total > 99 ? '99+' : `${total}`;
  }
}
