import { User } from './User';

// 私信收件箱 /u/{username}/messages.json 的一行会话。
//
// Discourse 私信会话本质是一个 archetype=private_message 的主题(有 topicId),
// 列表接口只给会话的摘要层(标题/参与者/最后回复时间/未读);点开详情仍然走
// 现有原生主题详情页(TopicDetailPage)——那页渲染任意主题,私信会话同样适用。
export interface MessageThread {
  topicId: number;
  // 会话标题(服务端 fancy_title 优先、回退 title,已解码 HTML 实体)。
  title: string;
  // 会话参与者(服务端 participants 精简对象,无 flair;含自己)。群聊第一人即会话名来源。
  participants: User[];
  // 最后回复时间(ISO),行内用 RelativeTime 转「N 天前」。
  lastPostedAt?: string;
  // 未读:unseen=true 表示有新消息未读(列表接口的已读位)。
  unseen: boolean;
  // 摘要(excerpt,可能为空)。
  excerpt: string;
  // 回复数(posts_count)。
  postsCount: number;
  // 我读到的最新楼层(last_read_post_number),与 posts_count 比较可得「N 条新消息」。
  lastReadPostNumber?: number;
  // slug(打开详情可回传;列表接口不一定给)。
  slug?: string;
}

// 一页收件箱内容:会话行 + 是否还有更多(服务端固定每页 50 条,满页即视为还有)。 
export interface MessageInboxPage {
  threads: MessageThread[];
  hasMore: boolean;
}
