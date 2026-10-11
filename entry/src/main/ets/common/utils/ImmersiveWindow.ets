import window from '@ohos.window';
import display from '@ohos.display';

// 系统栏插图高度(vp)的 AppStorage 键:根部 Navigation 读它做常驻避让 padding,
// 各组件需要状态栏高度时也统一读这里(不再各自 getWindowAvoidArea)。
export const SYS_TOP_INSET_KEY: string = 'sysTopInsetVp';
export const SYS_BOTTOM_INSET_KEY: string = 'sysBottomInsetVp';
// 前摄挖孔避让区(screen 坐标, vp)。挖孔通常在顶部居中或侧边,由 TYPE_CUTOUT 报成若干矩形;
// 取并集包围盒后拆成四个标量(而非打包对象)——AppStorage 改对象字段不穿透 @StorageProp,
// 标量键是唯一可靠形态。无挖孔(模拟器/侧边挖孔不遮挡)时四值全为 0。
export const CUTOUT_LEFT_INSET_KEY: string = 'cutoutLeftVp';
export const CUTOUT_TOP_INSET_KEY: string = 'cutoutTopVp';
export const CUTOUT_WIDTH_INSET_KEY: string = 'cutoutWidthVp';
export const CUTOUT_HEIGHT_INSET_KEY: string = 'cutoutHeightVp';

/**
 * 常驻沉浸式窗口:启动即 setWindowLayoutFullScreen(true),整个 App 生命周期不再切换窗口布局模式。
 *
 * 动机:本工程 UI 处处按沉浸式写(根 Stack expandSafeArea TOP+BOTTOM、各浮层遮罩 expandSafeArea、
 * 页面列表下探手势条),但窗口过去从未真正进全屏布局,导致每个要铺满物理屏的功能(评论浮层、图片预览)
 * 都得各自临时切全屏 + 手动补偿背景位移 + 掩藏窗口重排——同一个坑反复打补丁。
 * 改为常驻全屏后:内容避让统一由根部 Navigation 的 padding(读本模块写入的插图高度)完成,
 * 浮层天然全屏,所有临时切换/补偿代码删除。
 *
 * 插图高度经 avoidAreaChange 持续同步(旋转、折叠形态变化);图片预览期间隐藏状态栏会让
 * TYPE_SYSTEM 上边归零,但那只是"隐藏",背景布局不该塌——预览方先 suppressInsetSync(true)
 * 再隐藏,恢复显示后放开,期间归零事件被丢弃,背景 padding 全程稳定。
 */
export class ImmersiveWindow {
  private static suppressed: boolean = false;
  private static win?: window.Window = undefined;
  // 最近一次收到的深色标志:窗口未就绪时(ThemeManager.init 早于 onWindowStageCreate)先记下,就绪后补应用。
  private static lastDark: boolean = false;

  // 主窗口就绪后调用一次(EntryAbility.onWindowStageCreate):切常驻全屏并开始同步插图高度。
  static init(win: window.Window): void {
    ImmersiveWindow.win = win;
    win.setWindowLayoutFullScreen(true).catch(() => {});
    // 常驻全屏下系统不再按颜色模式自动适配状态栏图标色,须随主题手动设置(启动补一次)。
    ImmersiveWindow.applyBarContentColor(ImmersiveWindow.lastDark);
    ImmersiveWindow.syncInsets(win);
    try {
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        // 只关心系统栏与挖孔区(键盘避让由各输入组件自理)。
        if (data.type === window.AvoidAreaType.TYPE_SYSTEM
          || data.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR
          || data.type === window.AvoidAreaType.TYPE_CUTOUT) {
          ImmersiveWindow.syncInsets(win);
        }
      });
    } catch (err) {
    }
  }

  // 暂停/恢复插图同步:图片预览隐藏状态栏前置 true(丢弃归零事件),恢复显示后置 false。
  static suppressInsetSync(on: boolean): void {
    ImmersiveWindow.suppressed = on;
  }

  // 按主题深浅设置系统栏图标色:深色浅图标、浅色深图标。ThemeManager 每次重算 appIsDark 时推送;
  // 窗口尚未就绪时先记住,init 时补应用。
  static applyBarContentColor(dark: boolean): void {
    ImmersiveWindow.lastDark = dark;
    const win: window.Window | undefined = ImmersiveWindow.win;
    if (win === undefined) {
      return;
    }
    const content: string = dark ? '#FFFFFF' : '#000000';
    win.setWindowSystemBarProperties({
      statusBarContentColor: content,
      navigationBarContentColor: content
    }).catch(() => {});
  }

  private static syncInsets(win: window.Window): void {
    if (ImmersiveWindow.suppressed) {
      return;
    }
    try {
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const indicator: window.AvoidArea =
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      // Ability 上下文没有 px2vp 全局函数,用屏幕密度手动换算。
      const density: number = display.getDefaultDisplaySync().densityPixels;
      if (density <= 0) {
        return;
      }
      AppStorage.setOrCreate(SYS_TOP_INSET_KEY, sys.topRect.height / density);
      AppStorage.setOrCreate(SYS_BOTTOM_INSET_KEY, indicator.bottomRect.height / density);
      // 挖孔避让区:四块矩形(顶/左/右/底)取并集包围盒。多数机型是顶部居中的单块;
      // 横屏/异形屏可能拆到侧边,并集兜住各种形态。坐标按物理像素从窗口左上角起,除密度成 vp。
      const cutout: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT);
      let cutLeft: number = Number.MAX_VALUE;
      let cutTop: number = Number.MAX_VALUE;
      let cutRight: number = 0;
      let cutBottom: number = 0;
      const cutRects: (window.Rect)[] = [cutout.topRect, cutout.leftRect, cutout.rightRect, cutout.bottomRect];
      for (let index: number = 0; index < cutRects.length; index++) {
        const rect: window.Rect = cutRects[index];
        if (rect.width > 0 && rect.height > 0) {
          cutLeft = Math.min(cutLeft, rect.left);
          cutTop = Math.min(cutTop, rect.top);
          cutRight = Math.max(cutRight, rect.left + rect.width);
          cutBottom = Math.max(cutBottom, rect.top + rect.height);
        }
      }
      if (cutRight > cutLeft && cutBottom > cutTop) {
        AppStorage.setOrCreate(CUTOUT_LEFT_INSET_KEY, cutLeft / density);
        AppStorage.setOrCreate(CUTOUT_TOP_INSET_KEY, cutTop / density);
        AppStorage.setOrCreate(CUTOUT_WIDTH_INSET_KEY, (cutRight - cutLeft) / density);
        AppStorage.setOrCreate(CUTOUT_HEIGHT_INSET_KEY, (cutBottom - cutTop) / density);
      } else {
        AppStorage.setOrCreate(CUTOUT_LEFT_INSET_KEY, 0);
        AppStorage.setOrCreate(CUTOUT_TOP_INSET_KEY, 0);
        AppStorage.setOrCreate(CUTOUT_WIDTH_INSET_KEY, 0);
        AppStorage.setOrCreate(CUTOUT_HEIGHT_INSET_KEY, 0);
      }
    } catch (err) {
    }
  }
}
