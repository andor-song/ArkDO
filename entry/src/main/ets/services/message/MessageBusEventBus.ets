import { Log } from '../logging/Log';
import { ChallengeEventBus } from '../challenge/ChallengeEventBus';
import { ChallengeState } from '../network/NetworkTypes';

const LOG_TAG: string = '[ArkDO][MessageBus]';

// Presence 频道 payload 里的用户(BasicUserSerializer：id/username/name/avatar_template)。
export interface MessageBusPresenceUser {
  id?: number;
  username?: string;
  name?: string;
  avatar_template?: string;
}

// /latest、/new、/unread 三个频道消息里的 payload(topic_tracking_state.rb 的 publish_* 方法)。
// 频道本身是全局的、不随当前列表的筛选条件变,要不要算进当前列表全靠这里的字段自行比对。
// tags 只给 id 不给名字,且受服务端 SiteSetting.tagging_enabled 控制,可能整个缺席。
export interface MessageBusTopicTag {
  id?: number;
}

export interface MessageBusTopicPayload {
  category_id?: number;
  tags?: MessageBusTopicTag[];
  // /new 频道(publish_new)独有:建帖时间。/latest 的 payload 没有它,只有 bumped_at ——
  // 这正是「被回复顶起来的老帖」在 /latest 上无法与新帖区分的原因。
  created_at?: string;
}

export interface MessageBusData {
  topic_id?: number;
  message_type?: string;
  payload?: MessageBusTopicPayload;
  // /presence/<channel> 频道 payload(presence_channel.rb:335-347)：谁进入/离开"正在回复"。
  entering_users?: MessageBusPresenceUser[];
  leaving_user_ids?: number[];
  count_delta?: number;
  // /notification/<id> 频道 payload 的未读数（user.rb publish_notifications_state:921-931，已核源码）。
  // 铃铛角标用 all_unread_notifications_count（总未读，含私信）；unread_notifications 只含
  // high_priority=FALSE，漏私信，不能用于角标。unread_high_priority_notifications 为高优先级子集。
  all_unread_notifications_count?: number;
  unread_notifications?: number;
  unread_high_priority_notifications?: number;
  // /topic/<id> 频道 payload（post.rb publish_change_to_clients!:229-239，已核源码）。
  // id=帖子 id；post_number=楼号；type=动作类型（新楼为 'created'，还有 revised/deleted 等）。
  id?: number;
  post_number?: number;
  type?: string;
  // 整帖刷新标记（上游 topic.js onMessage：data.reload_topic 为真时整帖重载）。
  reload_topic?: boolean;
  // ---- Discourse Chat 实时事件（聊天页用）----
  // /chat/{channel_id} 频道（publisher.rb）：
  //   · sent     data = { chat_message: <MessageSerializer>, type: 'sent', staged_id }
  //   · edit/refresh/delete/restore/reaction ...  data = { ... , type: <action> }
  // 这里的 chat_message 是 MessageSerializer 的原样对象（含 id/message/cooked/user/...），
  // 由聊天页按需解析成 ChatMessage，不在此强建模——字段随站点版本会漂移，保持透传最稳。
  chat_message?: object;
  // sent 事件附带的本端暂存 id：发消息时我们传 staged_id，Web 端据此把临时气泡替换成
  // 服务端正式消息（chat-channel-subscription-manager.js 同样读它对齐）。
  staged_id?: number;
  // /chat/user-tracking-state/{user_id} 频道 payload：任意频道有未读变化都会推。
  channel_id?: number;
  last_read_message_id?: number;
  unread_count?: number;
  mention_count?: number;
}

export interface MessageBusEvent {
  type: string;
  channel?: string;
  messageId?: number;
  data?: MessageBusData;
  statusCode?: number;
  stage?: string;
  message?: string;
}

export type MessageBusListener = (event: MessageBusEvent) => void;

export function parseMessageBusEvent(payload: string): MessageBusEvent | undefined {
  try {
    const event: MessageBusEvent = JSON.parse(payload) as MessageBusEvent;
    if (!event || typeof event.type !== 'string') {
      return undefined;
    }
    if (event.type === 'message') {
      if (typeof event.channel !== 'string' || typeof event.messageId !== 'number' ||
        !Number.isFinite(event.messageId)) {
        return undefined;
      }
    }
    return event;
  } catch (error) {
    return undefined;
  }
}

// 首页实时提示会用到的两个频道。哪个能用取决于当前排序,见 HomePage.incomingTopicsChannel。
export const LATEST_TOPICS_CHANNEL: string = '/latest';
export const NEW_TOPICS_CHANNEL: string = '/new';

/**
 * /latest 频道上会计入「新的或更新的话题」的 message_type(白名单)。
 *
 * 这个频道跑的不止新话题 —— topic_tracking_state.rb 往 LATEST_MESSAGE_BUS_CHANNEL 发四种消息:
 *   · latest    (publish_latest) 话题被顶起来了     → 计入
 *   · new_topic (publish_new)    新建话题           → 计入
 *   · muted     (publish_muted)   有人静音了该话题   → 不计
 *   · unmuted   (publish_unmuted) 有人取消静音       → 不计
 * 官方前端 topic-tracking-state.js 的 notifyIncoming 同样只认前两种。
 *
 * 用白名单而不是「排除 muted/unmuted」的黑名单:将来 Discourse 往这个频道加新类型时,
 * 白名单默认不计、顶多漏报;黑名单会默默把它算成新话题,又变回现在这个 bug。
 */
const LATEST_CHANNEL_MESSAGE_TYPES: string[] = ['latest', 'new_topic'];

/**
 * /new 频道的白名单:只认 new_topic。
 *
 * 「最新发布」按 created_at 排,被回复顶起来的老帖不该进提示条 —— 所以这里绝不能把 'latest' 放进来。
 * publish_new 只在建帖时推一次(实测 meta 上连续 70 条消息全是 new_topic、highest_post_number 都是 1、
 * topic_id 零重复),回复走的是 /latest 与 /unread/{user_id},不碰这个频道。
 */
const NEW_CHANNEL_MESSAGE_TYPES: string[] = ['new_topic'];

/** 该频道上算「新话题」的 message_type 白名单。未知频道按 /latest 那套处理(更宽松的那个)。 */
function incomingTopicMessageTypes(channel: string | undefined): string[] {
  return channel === NEW_TOPICS_CHANNEL ? NEW_CHANNEL_MESSAGE_TYPES : LATEST_CHANNEL_MESSAGE_TYPES;
}

export function extractMessageBusTopicId(event: MessageBusEvent | undefined): number | undefined {
  if (!event || event.type !== 'message' || !event.data) {
    return undefined;
  }
  const messageType: string | undefined = event.data.message_type;
  if (messageType === undefined || incomingTopicMessageTypes(event.channel).indexOf(messageType) < 0) {
    return undefined;
  }
  const topicId: number | undefined = event.data.topic_id;
  if (topicId === undefined || !Number.isFinite(topicId) || topicId <= 0) {
    return undefined;
  }
  return Math.floor(topicId);
}

// 取该消息所属版块 id。拿不到(payload 缺席或字段非法)回 undefined,由调用方决定宽松还是从严。
export function extractMessageBusCategoryId(event: MessageBusEvent | undefined): number | undefined {
  if (!event || event.type !== 'message' || !event.data || !event.data.payload) {
    return undefined;
  }
  const categoryId: number | undefined = event.data.payload.category_id;
  if (categoryId === undefined || !Number.isFinite(categoryId) || categoryId <= 0) {
    return undefined;
  }
  return Math.floor(categoryId);
}

// 取该消息的建帖时间(ISO 串,只有 /new 频道的 payload 带)。拿不到回空串,由调用方决定放行还是从严。
export function extractMessageBusCreatedAt(event: MessageBusEvent | undefined): string {
  if (!event || event.type !== 'message' || !event.data || !event.data.payload) {
    return '';
  }
  const createdAt: string | undefined = event.data.payload.created_at;
  return typeof createdAt === 'string' ? createdAt : '';
}

// 从 /topic/<id> 频道事件里取"新建帖子"的 post id：仅 type==='created' 且 data.id 为正整数时返回。
// 其它动作类型（revised/deleted/...）与无 type 的整帖刷新消息一律返回 undefined（P2 MVP 只做新楼）。
// 从 config-ready 状态事件里取长轮询的 clientId。
// presence 上行(/presence/update)必须与长轮询用**同一个** client_id,否则服务端认不出是同一客户端;
// clientId 是脚本内生成的,只出现在这条状态事件的自由文本里,所以从这里回捞。
export function extractMessageBusClientId(event: MessageBusEvent | undefined): string | undefined {
  if (!event || event.type !== 'status' || event.stage !== 'config-ready') {
    return undefined;
  }
  const message: string | undefined = event.message;
  if (message === undefined) {
    return undefined;
  }
  const marker: string = 'clientId=';
  const at: number = message.indexOf(marker);
  if (at < 0) {
    return undefined;
  }
  const rest: string = message.substring(at + marker.length);
  const space: number = rest.indexOf(' ');
  const value: string = space >= 0 ? rest.substring(0, space) : rest;
  return value.length > 0 ? value : undefined;
}

export type TopicPostChangeKind = 'created' | 'revised' | 'deleted' | 'topic-reload';

export interface TopicPostChange {
  kind: TopicPostChangeKind;
  postId?: number;
  postNumber?: number;
}

/**
 * 解析 `/topic/<id>` 频道上的楼层变更事件。
 *
 * 判据照上游源码（不是我们猜的）：
 *  · 动作类型来自 `post.rb#publish_change_to_clients!`：新建 `:created`(post_creator.rb:658)、
 *    修订 `:revised`(post_revisor.rb:906)、软删 `:deleted`、永久删 `:destroyed`(post_destroyer.rb:255)。
 *    后两者 UI 行为一致（这层楼没了），这里归并成 `deleted`。
 *  · 整帖刷新的真实信号是 `data.reload_topic === true`（`topic.js#onMessage`），
 *    **不是**"缺少 type"——缺 type 且无该标记时上游自己也只是 `console.warn`，我方忽略。
 *  · `recovered`/`acted`/`rebaked` 等其余动作不影响楼层列表，忽略。
 */
export function extractTopicPostChange(event: MessageBusEvent | undefined): TopicPostChange | undefined {
  if (!event || event.type !== 'message' || event.data === undefined) {
    return undefined;
  }
  const channel: string | undefined = event.channel;
  if (channel === undefined || !channel.startsWith('/topic/')) {
    return undefined;
  }
  const data: MessageBusData = event.data;
  if (data.reload_topic === true) {
    return { kind: 'topic-reload' };
  }
  const action: string | undefined = data.type;
  if (action === undefined) {
    return undefined;
  }
  let kind: TopicPostChangeKind | undefined = undefined;
  if (action === 'created') {
    kind = 'created';
  } else if (action === 'revised') {
    kind = 'revised';
  } else if (action === 'deleted' || action === 'destroyed') {
    kind = 'deleted';
  }
  if (kind === undefined) {
    return undefined;
  }
  const postId: number | undefined = data.id;
  if (postId === undefined || !Number.isFinite(postId) || postId <= 0) {
    return undefined;
  }
  const change: TopicPostChange = { kind: kind, postId: Math.floor(postId) };
  const postNumber: number | undefined = data.post_number;
  if (postNumber !== undefined && Number.isFinite(postNumber) && postNumber > 0) {
    change.postNumber = Math.floor(postNumber);
  }
  return change;
}


export class MessageBusEventBus {
  private static listeners: Map<number, MessageBusListener> = new Map();
  private static nextListenerId: number = 0;

  static subscribe(listener: MessageBusListener): () => void {
    const listenerId: number = MessageBusEventBus.nextListenerId;
    MessageBusEventBus.nextListenerId++;
    MessageBusEventBus.listeners.set(listenerId, listener);
    return () => {
      MessageBusEventBus.listeners.delete(listenerId);
    };
  }

  static publishPayload(payload: string): void {
    const event: MessageBusEvent | undefined = parseMessageBusEvent(payload);
    if (!event) {
      Log.i(`${LOG_TAG} ignored malformed bridge payload`);
      return;
    }
    if (event.type === 'challenge') {
      const statusCode: number = event.statusCode !== undefined && Number.isFinite(event.statusCode)
        ? event.statusCode : 0;
      ChallengeEventBus.notifyChallengeRequired('/message-bus', statusCode, ChallengeState.REQUIRED);
    }
    MessageBusEventBus.publish(event);
  }

  static publish(event: MessageBusEvent): void {
    const listeners: MessageBusListener[] = [];
    MessageBusEventBus.listeners.forEach((listener: MessageBusListener) => {
      listeners.push(listener);
    });
    Log.i(`${LOG_TAG} event type=${event.type} stage=${event.stage ?? ''} channel=${event.channel ?? ''} ` +
      `messageId=${event.messageId ?? 0} status=${event.statusCode ?? 0} message=${event.message ?? ''} ` +
      `listeners=${listeners.length}`);
    for (let index: number = 0; index < listeners.length; index++) {
      try {
        listeners[index](event);
      } catch (error) {
        Log.i(`${LOG_TAG} listener failed error=${JSON.stringify(error)}`);
      }
    }
  }
}
