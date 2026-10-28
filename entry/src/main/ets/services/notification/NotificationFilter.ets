/**
 * 通知按类型筛选(纯函数与常量表,本地 harness 可跑)。
 *
 * 上游事实(核对过 Discourse 源码,别凭印象改):
 *  - 参数名是 `filter_by_types=<类型名逗号分隔>`,**不是** `filter=`
 *    (app/controllers/notifications_controller.rb:19-24)。
 *  - 它按 `Notification.types[name.to_sym]` 反查编号,所以这里必须用**服务端的名字**,
 *    不是本仓 NotificationApi 里那组 T_* 常量名(T_GROUP_MENTIONED vs 上游 group_mention 就差一个字母)。
 *  - 分组依据取本仓 describe() 的中文文案:「回复了你/引用了你/回复了主题/引用了你的帖子」
 *    归到回复,「赞了你的帖子/点了表情回应」归到点赞,别把 boost(「为你的帖子助力」)算成点赞。
 *  - 「全部」不发该参数:发空串会被上游当成「筛选一个类型都没有」而返回空列表。
 */

export interface NotificationFilterOption {
  // 稳定标识,进 ForEach key 与选中态比较,不改文案就能换标签。
  key: string;
  label: string;
  // 发给服务端的类型名。空数组=不发参数(全部)。
  typeNames: string[];
}

export const NOTIFICATION_FILTER_ALL: string = 'all';

export const NOTIFICATION_FILTER_OPTIONS: NotificationFilterOption[] = [
  { key: NOTIFICATION_FILTER_ALL, label: '全部', typeNames: [] },
  { key: 'replies', label: '回复', typeNames: ['replied', 'quoted', 'posted', 'linked', 'linked_consolidated'] },
  { key: 'mentions', label: '提及', typeNames: ['mentioned', 'group_mention'] },
  {
    key: 'messages',
    label: '私信',
    typeNames: ['private_message', 'invited_to_private_message', 'group_message_summary',
      'chat_message', 'chat_mentioned', 'chat_quoted']
  },
  { key: 'likes', label: '点赞', typeNames: ['liked', 'liked_consolidated', 'reaction'] }
];

// 按 key 取类型名。未知 key(持久化值被改坏/版本间键名变过)一律退回「全部」,
// 绝不退回空数组——空数组在上游是「筛选结果为空」,那会让通知页看起来一条通知都没有。
export function notificationFilterTypeNames(key: string, options: NotificationFilterOption[] = NOTIFICATION_FILTER_OPTIONS): string[] {
  for (let index: number = 0; index < options.length; index++) {
    if (options[index].key === key) {
      return options[index].typeNames;
    }
  }
  return [];
}

/**
 * 拼 /notifications.json 的查询路径。
 *
 * 顺序固定 limit → offset → recent → filter_by_types:recent 那一对参数是「进页面 bump seen」,
 * 只有首屏带;翻页与筛选后的重载都不该重复 bump(参见 NotificationApi.load 的注释)。
 */
export function buildNotificationsPath(
  limit: number, offset: number, recent: boolean,
  typeNames?: string[]
): string {
  let path: string = `/notifications.json?limit=${limit}&offset=${offset}`;
  if (recent) {
    path += '&recent=true&bump_last_seen_reviewable=true';
  }
  if (typeNames !== undefined && typeNames.length > 0) {
    path += `&filter_by_types=${typeNames.join(',')}`;
  }
  return path;
}
