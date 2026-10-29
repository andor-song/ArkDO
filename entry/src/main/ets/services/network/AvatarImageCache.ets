import { BridgeImageLoader, ImageCacheStats } from './BridgeImageLoader';

const LOG_TAG: string = '[ArkDO][Avatar]';
// 并发取图上限:头像一次可能几十张,限流避免瞬间灌爆 host webview 的 runJavaScript 通道。
const MAX_CONCURRENCY: number = 5;
// 已解码 PixelMap 内存缓存上限。超出按插入序淘汰最旧(仅丢引用不 release,防止仍在显示的图被销毁崩溃)。
// 这道闸原来是 160,真机实测证明它**抢在字节预算之前**把缓存打死:一个 4282 楼的帖(2496114)
// 里光头像就远超 160 个不同用户,[ArkDO][Avatar] stats 的 213 次采样有 212 次 evicted=true、
// 全程 cache=160/160,而 bytes 只到 5.6/48MB —— 等于一边疯狂重新下载头像,一边把 42MB 预算空放着。
// 现在把条数抬到不会先碰到的位置,让**字节预算成为真正生效的那道闸**(单张 96px 头像解码后约
// 36KB,16MB ≈ 450 张,够一屏十几屏的滚动窗口复用),内存上限也从 48MB 收到 16MB 更好预测。
const MAX_CACHE_ENTRIES: number = 800;
// 头像本身只有几十到几百 px,不需要降采样,原尺寸解码。
const MAX_PIXEL_SIDE: number = 0;
// 字节预算:这条才是主闸(见上)。也是「站点把头像配成了大图」时的硬上限。
const MAX_CACHE_BYTES: number = 16 * 1024 * 1024;

/**
 * 头像 PixelMap 缓存。原生 Image 走系统 netstack 会被 SNI 封锁(TLS 握手 RST),
 * 故头像统一经 host webview(能藏 SNI 过盾)取字节,解码成 PixelMap 供 UserAvatar 显示。
 * 单例:UserAvatar 深层嵌套拿不到注入的 bridge,由 RootTabPage 在 host 就绪处 attachBridge 一次。
 * 取字节/解码/限流/淘汰的实现在 BridgeImageLoader,与正文图(ContentImageCache)共用。
 */
export class AvatarImageCache extends BridgeImageLoader {
  private static instance: AvatarImageCache = new AvatarImageCache();

  constructor() {
    super(LOG_TAG, MAX_CONCURRENCY, MAX_CACHE_ENTRIES, MAX_PIXEL_SIDE, MAX_CACHE_BYTES);
  }

  static getInstance(): AvatarImageCache {
    return AvatarImageCache.instance;
  }

  // 存储设置页用:清空头像缓存并返回释放字节数。
  static clearAll(): number {
    return AvatarImageCache.instance.clear();
  }

  static statsOf(): ImageCacheStats {
    return AvatarImageCache.instance.stats();
  }
}
