// Discourse /notifications.json 的原始结构(仅取用到的字段)。
export interface RawNotificationData {
  topic_title?: string;
  display_username?: string;
  original_username?: string;
  username?: string;
  group_name?: string;
  badge_name?: string;
  badge_slug?: string;
  badge_id?: number;
  count?: number;
  // 聊天类通知(Chat 进核心后的 chat_mentioned/chat_message/chat_quoted)带的频道 id。
  // 有它才能直接进原生聊天页;站点没装 Chat 时这个字段根本不存在,解析按缺省处理。
  chat_channel_id?: number;
}

export interface RawNotification {
  id?: number;
  notification_type?: number;
  read?: boolean;
  high_priority?: boolean;
  created_at?: string;
  post_number?: number;
  topic_id?: number;
  fancy_title?: string;
  slug?: string;
  acting_user_avatar_template?: string;
  acting_user_name?: string;
  data?: RawNotificationData;
  // 站内相对地址(/t/… 或 /chat/c/…)。NotificationSerializer 给移动端的就是这一个字段;
  // 本仓此前不读它(所有跳转按 topic_id 走),现在用它兜底判「这条通知是不是聊天」。
  url?: string;
}

export interface RawNotificationsResponse {
  notifications?: RawNotification[];
}

// 通知的展示模型:解析时已把类型映射成图标/颜色/文案,行组件直接读取即可。
export interface NotificationItem {
  id: number;
  type: number;
  read: boolean;
  createdAt: string;
  actorName: string;         // 发起人展示名;系统类通知为空串
  actorUsername: string;     // 用于头像首字母兜底
  avatarTemplate?: string;   // 发起人头像模板(交给 UserAvatar 解析)
  actionText: string;        // "回复了你"/"你获得了徽章" 等
  title: string;             // 帖子标题 / 徽章名
  topicId?: number;
  postNumber?: number;
  slug?: string;
  // 聊天频道 id:仅聊天类通知有值,且 >0。点击分流的第一判据(见 NotificationRouting)。
  chatChannelId?: number;
  // 通知自带的站内地址,chatChannelId 缺位时的兜底证据。
  url?: string;
  // 服务端标的高优先级(私信那类)。单条标记已读时要减哪一个桶,看这个而不是重抄一份类型编号表。
  highPriority?: boolean;
  iconId: string;            // FontAwesome 图标 id(角标/系统圈用)
  iconColor: string;         // 角标颜色
}
