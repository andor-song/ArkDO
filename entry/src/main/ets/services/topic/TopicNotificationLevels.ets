/**
 * 话题通知等级的纯逻辑层（档位定义、取值归一、请求拼装）。
 *
 * 为什么单独一层：档位是**服务端定义的整数**，不是我们能自创的东西。上游
 * `lib/notification_levels.rb` 的 `topic_levels` 是
 * `{ muted: 0, regular: 1, normal: 1(别名), tracking: 2, watching: 3 }`，
 * 写入端点 `POST /t/:topic_id/notifications`（`topics#set_notifications`，
 * form 参数 `notification_level`，值 `.to_i`）。把「数字 ↔ 文案 ↔ 请求体」集中在
 * 一处且不碰任何网络/UI，改档位时只动这里，也才能被单测覆盖。
 *
 * 两个容易踩空的地方，都在这里显式处理：
 *  1. **读**：`TopicViewDetailsSerializer#notification_level` 在用户从没为该帖设过时
 *     会**回落 regular(1)**，而不是给 null。所以「看到 1」不能推断「用户主动选了正常」，
 *     更不能拿它当「服务端支持这个功能」的证据 —— 旧站点/插件裁剪时字段可能整个缺失。
 *  2. **写**：服务端对超范围的整数不做校验直接落库（`params[:notification_level].to_i`），
 *     所以客户端必须自己挡住非法值，别让 UI 传出一个 7 之类的东西。
 */

export const NOTIFICATION_LEVEL_MUTED: number = 0;
export const NOTIFICATION_LEVEL_REGULAR: number = 1;
export const NOTIFICATION_LEVEL_TRACKING: number = 2;
export const NOTIFICATION_LEVEL_WATCHING: number = 3;

export interface NotificationLevelOption {
  // 服务端取值。
  level: number;
  // 菜单里的主文案。
  label: string;
  // 一行说明：这一档到底会收到什么。文案照网页版措辞，避免同一功能两套说法。
  hint: string;
  // FontAwesome 图标 id（rawfile/fa_icons），与官网用图标保持一致。
  iconId: string;
}

/**
 * 四档，顺序即展示顺序（从最安静到最吵）。
 * 「正常」是 Discourse 的默认档：只在有新回复时通知；
 * 「跟踪」= 有人回复就通知且自动更新已读位置；「关注」= 连编辑也通知。
 */
export const TOPIC_NOTIFICATION_OPTIONS: NotificationLevelOption[] = [
  {
    level: NOTIFICATION_LEVEL_WATCHING,
    label: '关注',
    hint: '新回复与编辑都提醒，帖子始终留在未读里',
    iconId: 'discourse-bell-one'
  },
  {
    level: NOTIFICATION_LEVEL_TRACKING,
    label: '跟踪',
    hint: '有新回复就提醒，读到新楼层自动标记已读',
    iconId: 'bullseye'
  },
  {
    level: NOTIFICATION_LEVEL_REGULAR,
    label: '正常',
    hint: '默认档：有人回应你参与过的讨论时才提醒',
    iconId: 'far-bell'
  },
  {
    level: NOTIFICATION_LEVEL_MUTED,
    label: '静默',
    hint: '这个帖子不再发任何通知',
    iconId: 'far-bell-slash'
  }
];

/** 已知档位（0~3）。其余值一律视为「服务端没告诉我们」。 */
export function isKnownNotificationLevel(level: number | undefined): boolean {
  return level === NOTIFICATION_LEVEL_MUTED || level === NOTIFICATION_LEVEL_REGULAR ||
    level === NOTIFICATION_LEVEL_TRACKING || level === NOTIFICATION_LEVEL_WATCHING;
}

/**
 * 归一成本地可显示的档位：未知/缺失一律按「正常」显示。
 *
 * 注意这只是**显示回落**，不代表用户设过它 —— 上游本来就会为没设过的人回 regular(1)。
 */
export function normalizeNotificationLevel(level: number | undefined): number {
  return isKnownNotificationLevel(level) ? (level as number) : NOTIFICATION_LEVEL_REGULAR;
}

/** 当前档位的文案（未知时给「正常」），用于顶栏菜单标题与勾选态比对。 */
export function describeNotificationLevel(level: number | undefined): string {
  return labelOf(normalizeNotificationLevel(level));
}

function labelOf(level: number): string {
  for (let index: number = 0; index < TOPIC_NOTIFICATION_OPTIONS.length; index++) {
    if (TOPIC_NOTIFICATION_OPTIONS[index].level === level) {
      return TOPIC_NOTIFICATION_OPTIONS[index].label;
    }
  }
  return '正常';
}

/**
 * 写入请求体。非法档位返回空串而不是拼出一个越界数字：
 * 服务端对 `notification_level` 只做 `.to_i`、不校验范围，客户端漏了就是脏数据。
 * 调用方见空串即放弃发请求。
 */
export function buildNotificationLevelBody(level: number): string {
  if (!isKnownNotificationLevel(level)) {
    return '';
  }
  return `notification_level=${level}`;
}

export function notificationLevelPath(topicId: number): string {
  return `/t/${topicId}/notifications`;
}
