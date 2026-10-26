/**
 * 长按应用图标的快捷入口（发帖 / 搜索 / 通知）—— want.parameters 的纯解析层。
 *
 * 为什么单独一层：hvigor 校验 shortcuts 时要求 label 必须是 `$string:` 资源引用（schema 的
 * pattern 不接受裸中文），而 wants[].parameters 只能是 **ASCII 字符串键值对**，所以配置文件里
 * 能放的只有英文动作码；把动作码翻成界面行为是 ArkTS 侧的事。这段映射不碰任何系统 API，
 * 因此能被 entry/src/test 直接覆盖 —— 而它恰恰最容易静默出错：动作码写错不会报错，
 * 只会"点了快捷入口没反应"。
 *
 * 刻意不做「新私信」快捷入口（官方 iOS App 三个入口里我们只做两个 + 通知）：
 * 私信只能对**某个具体用户**发起，而收件箱页没有"新建会话"的入口 —— 快捷入口落到一个
 * 走不通的页面，比不给入口更糟。
 */

// 与 resources/base/profile/shortcuts_config.json 里 wants[].parameters 的取值逐字对应。
export const QUICK_ACTION_COMPOSE: string = 'compose';
export const QUICK_ACTION_SEARCH: string = 'search';
export const QUICK_ACTION_NOTIFICATIONS: string = 'notifications';

// want.parameters 里携带动作码的键名（配置侧与解析侧必须用同一个字面量，故集中在此）。
export const QUICK_ACTION_WANT_KEY: string = 'arkdo_action';

// 令牌里记录写入时刻，超过这个年龄就不再执行（下面 quickActionOfToken 的说明）。
// 15 秒够覆盖"冷启动 → 根页挂载"的正常耗时，又短到不会让人在别的场景里撞上一个陈旧动作。
export const QUICK_ACTION_MAX_AGE_MS: number = 15000;

// 令牌值的分隔符：`动作码|写入时刻`。用竖线是因为动作码只含小写字母，不会与之冲突。
const TOKEN_SEPARATOR: string = '|';

/**
 * 白名单：把任意来源的动作码收敛成"已知 or 空串"。全模块只有这一处判白名单。
 *
 * 未知值一律返回空串 = 什么都不做。这条对两个调用方都成立：
 *  · want.parameters 可能与深链 / 推送共用同一个 onNewWant，乱认会把别的来源当成快捷入口执行；
 *  · AppStorage 里的令牌可能是**上一个版本**写入的值，升级后不该被照旧执行。
 */
function knownActionOrEmpty(action: string): string {
  if (action === QUICK_ACTION_COMPOSE || action === QUICK_ACTION_SEARCH ||
    action === QUICK_ACTION_NOTIFICATIONS) {
    return action;
  }
  return '';
}

/**
 * 从 want.parameters 取出快捷入口动作码。
 *
 * 先确认取到的是 string 再用：parameters 的实际类型是系统的 Record/Object，键值可能是任意类型。
 */
export function parseQuickAction(parameters: Object | undefined): string {
  if (parameters === undefined || parameters === null) {
    return '';
  }
  const raw: Object | undefined = (parameters as Record<string, Object>)[QUICK_ACTION_WANT_KEY];
  return typeof raw === 'string' ? knownActionOrEmpty(raw.trim()) : '';
}

/**
 * 给令牌盖时间戳：`动作码|时刻`。写入方（EntryAbility）与读取方（根页）都经过这里，
 * 格式只有一处定义。
 */
export function stampQuickAction(action: string, nowMs: number): string {
  return `${action}${TOKEN_SEPARATOR}${nowMs}`;
}

/**
 * 认领 AppStorage 里的待消费令牌，返回可执行的动作码（不该执行时返回空串）。
 *
 * 两道把关：
 *  · **白名单**：令牌可能是上一个版本写的未知值，升级后不该照旧执行。
 *  · **年龄**：未配置论坛时 Index 渲染的是引导页，根页压根没挂载、没人认领，令牌会一直躺在
 *    AppStorage 里；等用户配好论坛、根页终于挂载时，若照旧执行就会出现"配完论坛突然弹出发帖
 *    编辑器"这种完全对不上因果的行为。超过 QUICK_ACTION_MAX_AGE_MS 直接丢弃。
 *
 * 调用方认领后必须**立即清空令牌再执行动作**：只有一个消费者，但同一个动作被执行两遍的
 * 风险来自"挂载时认领一次 + @Watch 又一次"，先清就幂等了。
 */
export function quickActionOfToken(stored: string | undefined, nowMs: number): string {
  if (typeof stored !== 'string') {
    return '';
  }
  const separator: number = stored.indexOf(TOKEN_SEPARATOR);
  if (separator < 0) {
    return '';
  }
  const action: string = knownActionOrEmpty(stored.substring(0, separator).trim());
  if (action.length === 0) {
    return '';
  }
  const writtenAt: number = Number(stored.substring(separator + TOKEN_SEPARATOR.length));
  // 时刻不可解析（NaN）时按"陈旧"处理：宁可不执行，也不要拿一个来路不明的令牌去跳转。
  if (!isFinite(writtenAt) || nowMs - writtenAt > QUICK_ACTION_MAX_AGE_MS) {
    return '';
  }
  return action;
}
