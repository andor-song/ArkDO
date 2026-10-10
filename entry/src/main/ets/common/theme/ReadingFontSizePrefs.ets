import { Log } from '../../services/logging/Log';
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const LOG_TAG: string = '[ArkDO][ReadingFontSize]';
// 与 ThemeManager / TopicListStylePrefs 共用同一个 preferences 库,只是键不同。
const PREF_STORE_NAME: string = 'app_settings';
const PREF_KEY_BODY_FONT_SIZE: string = 'reading_body_font_size';
const PREF_KEY_LINE_HEIGHT_RATIO: string = 'reading_line_height_ratio';

// AppStorage 镜像 key:正文渲染组件(PostRichContent)用 @StorageProp 逐个绑定,拖动滑块即时重排。
// 用两个独立的 number key 而非一个打包对象:AppStorage 里放对象时,改其字段不会穿透到
// @StorageProp,正文不会重渲染。标量键是这条链路上唯一可靠的形态。
export const READING_BODY_FONT_SIZE_KEY: string = 'readingBodyFontSize';
export const READING_LINE_HEIGHT_RATIO_KEY: string = 'readingLineHeightRatio';

// ---------------------------------------------------------------------------
// 取值区间
//
// 与列表样式同一套考虑:下限之下正文就要比次要文字还小,没有阅读层次;上限再高两三行就
// 吃掉整屏,翻页成本陡增。行高存倍率而非绝对值:改字号时行高自动跟随,不会「字变大了
// 行距没跟上」。默认值一律等于改造前的硬编码值(正文 15 / 行高 22),老用户升级后分毫不变。
// ---------------------------------------------------------------------------

/** 正文基准字号。默认 15 即改造前的硬编码值。 */
export const READING_FONT_SIZE_MIN: number = 13;
export const READING_FONT_SIZE_MAX: number = 19;
export const READING_FONT_SIZE_DEFAULT: number = 15;

/** 行高倍率。默认 22 ÷ 15 = 1.4667,量化后 15×1.47≈22,与硬编码 22 一致。 */
export const READING_LINE_HEIGHT_RATIO_MIN: number = 1.2;
export const READING_LINE_HEIGHT_RATIO_MAX: number = 2.0;
export const READING_LINE_HEIGHT_RATIO_STEP: number = 0.05;
export const READING_LINE_HEIGHT_RATIO_DEFAULT: number = 1.47;

/** 标题相对正文的倍率(以默认 15 为基准):H1=22/15、H2=20/15、H3=17/15。 */
const HEADING_1_SCALE: number = 22 / 15;
const HEADING_2_SCALE: number = 20 / 15;
const HEADING_3_SCALE: number = 17 / 15;

/** 标题行高相对**标题字号**的倍率:H1=28/22、H2=26/20、H3=23/17。 */
const HEADING_1_LINE_SCALE: number = 28 / 22;
const HEADING_2_LINE_SCALE: number = 26 / 20;
const HEADING_3_LINE_SCALE: number = 23 / 17;

/** 阅读正文的一套可调样式。 */
export interface ReadingFontSizeStyle {
  bodyFontSize: number;
  lineHeightRatio: number;
}

function clampInt(value: number, min: number, max: number, fallback: number): number {
  if (!Number.isFinite(value)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, Math.round(value)));
}

export function clampReadingFontSize(value: number): number {
  return clampInt(value, READING_FONT_SIZE_MIN, READING_FONT_SIZE_MAX, READING_FONT_SIZE_DEFAULT);
}

/** 行高倍率保留两位小数:滑块步进 0.05,浮点累加会攒出 1.4700000000000002 这种值。 */
export function clampReadingLineHeightRatio(value: number): number {
  if (!Number.isFinite(value)) {
    return READING_LINE_HEIGHT_RATIO_DEFAULT;
  }
  const bounded: number = Math.min(READING_LINE_HEIGHT_RATIO_MAX, Math.max(READING_LINE_HEIGHT_RATIO_MIN, value));
  return Math.round(bounded * 100) / 100;
}

/** 全默认的一套样式。 */
export function defaultReadingFontSizeStyle(): ReadingFontSizeStyle {
  return {
    bodyFontSize: READING_FONT_SIZE_DEFAULT,
    lineHeightRatio: READING_LINE_HEIGHT_RATIO_DEFAULT
  };
}

// ---------------------------------------------------------------------------
// 派生度量
//
// 正文是整套排版的地基:标题、行内 code、角标都按正文比例缩放,才不出现「正文放大了标题
// 还挤成一坨」的失衡。默认值一律还原改造前的硬编码数字。
// ---------------------------------------------------------------------------

/** 正文行高。 */
export function readingBodyLineHeight(bodyFontSize: number, ratio: number): number {
  return Math.round(clampReadingFontSize(bodyFontSize) * clampReadingLineHeightRatio(ratio));
}

/** 标题字号(按层级):相对正文固定倍率,正文调档时标题同步缩放。 */
export function readingHeadingFontSize(bodyFontSize: number, level: number): number {
  const body: number = clampReadingFontSize(bodyFontSize);
  if (level <= 1) {
    return Math.round(body * HEADING_1_SCALE);
  }
  if (level === 2) {
    return Math.round(body * HEADING_2_SCALE);
  }
  return Math.round(body * HEADING_3_SCALE);
}

/** 标题行高(按层级):相对各自标题字号固定倍率。 */
export function readingHeadingLineHeight(bodyFontSize: number, level: number): number {
  const size: number = readingHeadingFontSize(bodyFontSize, level);
  if (level <= 1) {
    return Math.round(size * HEADING_1_LINE_SCALE);
  }
  if (level === 2) {
    return Math.round(size * HEADING_2_LINE_SCALE);
  }
  return Math.round(size * HEADING_3_LINE_SCALE);
}

/** 行内 code 字号:默认 14(比正文小一号),随正文蠕变但下限 12。 */
export function readingInlineCodeFontSize(bodyFontSize: number): number {
  return clampInt(clampReadingFontSize(bodyFontSize) - 1, 12, 18, 14);
}

/** 链接点击数角标字号:默认 14(比正文小一号)。角标高度取正文行高,单独由调用方传。 */
export function readingBadgeFontSize(bodyFontSize: number): number {
  return clampInt(clampReadingFontSize(bodyFontSize) - 1, 12, 18, 14);
}

// ---------------------------------------------------------------------------
// 持久化 + AppStorage 响应式镜像
//
// 写盘与预览分离:滑块 onChange 每帧都来,只更新内存与 AppStorage(正文即时跟手),
// 松手(SliderChangeMode.End/Click)时才调 flush 落盘,避免每帧 store.flush() 卡顿。
// ---------------------------------------------------------------------------
export class ReadingFontSizePrefs {
  private static cached: ReadingFontSizeStyle = defaultReadingFontSizeStyle();
  private static loaded: boolean = false;

  /** 当前生效的样式副本。 */
  static current(): ReadingFontSizeStyle {
    return {
      bodyFontSize: ReadingFontSizePrefs.cached.bodyFontSize,
      lineHeightRatio: ReadingFontSizePrefs.cached.lineHeightRatio
    };
  }

  /** 冷启动调用一次:读盘回填内存镜像并种入 AppStorage,保证正文首帧就按用户设置渲染。 */
  static load(context: common.UIAbilityContext | common.Context): void {
    if (!ReadingFontSizePrefs.loaded) {
      try {
        const store: preferences.Preferences =
          preferences.getPreferencesSync(context, { name: PREF_STORE_NAME });
        ReadingFontSizePrefs.cached = {
          bodyFontSize: clampReadingFontSize(
            ReadingFontSizePrefs.readNumber(store, PREF_KEY_BODY_FONT_SIZE, READING_FONT_SIZE_DEFAULT)),
          lineHeightRatio: clampReadingLineHeightRatio(
            ReadingFontSizePrefs.readNumber(store, PREF_KEY_LINE_HEIGHT_RATIO, READING_LINE_HEIGHT_RATIO_DEFAULT))
        };
        ReadingFontSizePrefs.loaded = true;
      } catch (error) {
        // 读失败按默认处理:纯外观设置,不该因存储异常影响启动。
        Log.i(`${LOG_TAG} load failed, fallback to defaults`);
        ReadingFontSizePrefs.cached = defaultReadingFontSizeStyle();
      }
    }
    ReadingFontSizePrefs.mirror();
  }

  static setBodyFontSize(value: number): number {
    ReadingFontSizePrefs.cached.bodyFontSize = clampReadingFontSize(value);
    ReadingFontSizePrefs.mirror();
    return ReadingFontSizePrefs.cached.bodyFontSize;
  }

  static setLineHeightRatio(value: number): number {
    ReadingFontSizePrefs.cached.lineHeightRatio = clampReadingLineHeightRatio(value);
    ReadingFontSizePrefs.mirror();
    return ReadingFontSizePrefs.cached.lineHeightRatio;
  }

  /** 恢复默认:内存 + 镜像 + 落盘一次到位。 */
  static resetDefaults(context: common.UIAbilityContext | common.Context): ReadingFontSizeStyle {
    ReadingFontSizePrefs.cached = defaultReadingFontSizeStyle();
    ReadingFontSizePrefs.mirror();
    ReadingFontSizePrefs.flush(context);
    return ReadingFontSizePrefs.current();
  }

  /** 把当前内存镜像整体落盘。滑块松手 / 恢复默认时各调一次。 */
  static flush(context: common.UIAbilityContext | common.Context): void {
    ReadingFontSizePrefs.loaded = true;
    try {
      const store: preferences.Preferences =
        preferences.getPreferencesSync(context, { name: PREF_STORE_NAME });
      store.putSync(PREF_KEY_BODY_FONT_SIZE, ReadingFontSizePrefs.cached.bodyFontSize);
      store.putSync(PREF_KEY_LINE_HEIGHT_RATIO, ReadingFontSizePrefs.cached.lineHeightRatio);
      store.flush();
      Log.i(`${LOG_TAG} saved body=${ReadingFontSizePrefs.cached.bodyFontSize} ` +
        `ratio=${ReadingFontSizePrefs.cached.lineHeightRatio}`);
    } catch (error) {
      Log.i(`${LOG_TAG} save failed`);
    }
  }

  private static mirror(): void {
    AppStorage.setOrCreate<number>(READING_BODY_FONT_SIZE_KEY, ReadingFontSizePrefs.cached.bodyFontSize);
    AppStorage.setOrCreate<number>(READING_LINE_HEIGHT_RATIO_KEY, ReadingFontSizePrefs.cached.lineHeightRatio);
  }

  private static readNumber(store: preferences.Preferences, key: string, fallback: number): number {
    const raw: preferences.ValueType = store.getSync(key, fallback);
    return typeof raw === 'number' ? raw : fallback;
  }
}
