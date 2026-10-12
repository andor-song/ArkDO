// 私信聊天的消息模型（Discourse Chat 原生消息）。
//
// 数据源：GET /chat/api/channels/{id}/messages 的 messages[]，
// 结构见 MessageSerializer（chat_message、created_at、user 内嵌、reactions 等）。
// 聊天页用 message、created_at、user、edited、deleted_at、thread 等字段渲染气泡。

// 消息参与者（MessageUserSerializer 精简版）。
export interface ChatMessageUser {
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
}

// 一条聊天消息。
export interface ChatMessage {
  id: number;
  // 消息正文（纯文本）。
  message: string;
  // 作者。
  user?: ChatMessageUser;
  // ISO 时间。
  created_at?: string;
  // 是否已编辑。
  edited?: boolean;
  // 删除时间（非空=已删除，占位显示）。
  deleted_at?: string;
  // 引用回复的目标消息 id（in_reply_to）。
  in_reply_to_id?: number;
  // 所属线程 id（单聊群聊都有，可能为 null）。
  thread_id?: number | null;
  // 表情回应 [{ emoji, count, usernames }]，聊天页暂只显示计数。
  reactions?: ChatMessageReaction[];
  // 消息 ID 连续可用作分页游标（before_message_id）。
  id_cursor?: number;
  // 乐观 UI：本端刚发出、尚未被 MessageBus sent 事件确认的暂存消息。
  // pending=true 期间本地渲染为「发送中」气泡；stagedId 与 sent 事件里的 staged_id 对齐。
  pending?: boolean;
  stagedId?: number;
  // 发送失败（乐观气泡被服务端拒绝/超时后标失败，供用户重试）。
  failed?: boolean;
}

// 表情回应（ChatMessageReaction 精简版，结构来自 chat_message 的 reactions[]）。
export interface ChatMessageReaction {
  emoji?: string;
  count?: number;
  usernames?: string[];
}
