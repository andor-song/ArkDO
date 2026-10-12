import { User } from './User';

// 私信收件箱的一行会话。
//
// 数据源有两个(按站点能力自适应):
//   - Discourse Chat 私聊频道(list 会话,linux.do 等启用 chat 的站点):GET /chat/api/me/channels
//     的 direct_message_channels[]。点开走通用 WebViewPage 加载聊天页(/chat/c/{title}/{id})。
//   - 传统私信主题(未启用 chat 的站点):GET /topics/private-messages/{username}.json
//     的 topic_list.topics[]。点开走原生主题详情页(TopicDetailPage,私信会话即主题)。
// 行渲染两源一致:头像 + 标题 + 副行(参与者/最后消息/时间) + 未读蓝点。
export interface MessageThread {
  // 唯一键:chat 频道 id 或私信主题 id。行 key 与打开目的地都用它。
  topicId: number;
  // 会话标题(服务端 fancy_title 优先、回退 title,已解码 HTML 实体;chat 源用对方用户名)。
  title: string;
  // 会话参与者(chat 源为对方头像;PM 源为 participants 精简对象,无 flair;含自己)。
  participants: User[];
  // 最后回复时间(ISO),行内用 RelativeTime 转「N 天前」。
  lastPostedAt?: string;
  // 未读:unseen=true 表示有新消息未读。
  unseen: boolean;
  // 摘要(excerpt,可能为空)。chat 源为最后一则消息的 excerpt。
  excerpt: string;
  // 回复数(posts_count)。chat 源没有该概念,恒 0。
  postsCount: number;
  // chat 源打开聊天页的 WebView 地址(/chat/c/{title}/{id})。非空优先走它。
  chatUrl?: string;
  // 以下为 PM 源专用:我读到的最新楼层 / slug。
  lastReadPostNumber?: number;
  slug?: string;
}

// 一页收件箱内容:会话行 + 是否还有更多。
export interface MessageInboxPage {
  threads: MessageThread[];
  hasMore: boolean;
}
