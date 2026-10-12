import { ChatMessage, ChatMessageReaction, ChatMessageUser } from '../../models/ChatMessage';
import { AppConstants } from '../../common/constants/AppConstants';
import { JsonNetworkClient, NetworkResult } from '../network/NetworkTypes';
import { forwardFailure, unexpectedResponse } from '../network/NetworkResults';
import { HtmlText } from '../content/HtmlText';

// 私信聊天服务(Discourse Chat 原生消息)。
//
// 数据链路(全部纯 HTTP,官方 chat 插件接口,已核源码 routes.rb/MessageSerializer):
//   - 拉历史:  GET  /chat/api/channels/{id}/messages?page_size=50&target_message_id=&direction=
//   - 发消息:  POST /chat/{channel_id}           body { message, staged_id }
//   - 标记已读: PUT  /chat/api/channels/{id}/read?message_id={mid}
// 实时收新消息不在这里:走 MessageBus 订阅 /chat/{channel_id}(sent 事件带完整消息对象,
// 由现有 ArkWebHost 长轮询回传,聊天页在 MessageBusEventBus 上监听过滤)。
//
// 发送是「乐观 UI」:先本地暂存 + 后台上传;成功等 MessageBus 的 sent 事件(staged_id 匹配)
// 用服务端正式消息替换本地气泡。延迟几秒没等到就静默重拉最新页兜底,绝不让用户看到假消息。
const LOG_TAG: string = '[ArkDO][Chat]';

// 一页聊天消息(含历史方向游标)。
export interface ChatMessagesPage {
  messages: ChatMessage[];
  hasMorePast: boolean;
}

// 发送结果:服务端确认的正式消息 id + 本端暂存 id(MessageBus sent 事件据此对齐)。
export interface ChatSendResult {
  messageId: number;
  stagedId: number;
}

// 解析 GET messages 响应的 messages[] 与 meta 游标。
// POST /chat/{channelId} 的响应:{ success, message_id }。
interface ChatSendResponse {
  success?: boolean;
  message_id?: number;
}

// meta 游标(单独声明接口,ArkTS 不允许对象字面量作为类型声明)。
interface ChatMessagesMeta {
  can_load_more_past?: boolean;
  can_load_more_future?: boolean;
}

interface ChatMessagesEnvelope {
  messages?: ChatMessageRaw[];
  meta?: ChatMessagesMeta;
}

// 服务端消息对象(MessageSerializer 精简字段)。导出供 MessageBus 事件("chat_message"
// 原样对象)复用同一套解析。
export interface ChatMessageRaw {
  id?: number;
  message?: string;
  cooked?: string;
  created_at?: string;
  edited?: boolean;
  deleted_at?: string;
  in_reply_to_id?: number;
  thread_id?: number | null;
  user?: object;
  reactions?: ChatMessageReactionRaw[];
}

export interface ChatMessageReactionRaw {
  emoji?: string;
  count?: number;
  usernames?: string[];
}

// 解析一条服务端消息对象 → 本地 ChatMessage。可用于 GET messages（逐条）与
// MessageBus sent 事件的 data.chat_message。解析失败（缺 id/正文）回 undefined。
export function parseChatMessage(raw: ChatMessageRaw): ChatMessage | undefined {
  const id: number | undefined = typeof raw.id === 'number' ? raw.id : undefined;
  if (id === undefined || id <= 0) {
    return undefined;
  }
  const text: string = typeof raw.message === 'string' && raw.message.length > 0
    ? raw.message : (typeof raw.cooked === 'string' ? HtmlText.toPlainText(raw.cooked) : '');
  const reactions: ChatMessageReactionRaw[] = raw.reactions ?? [];
  return {
    id: id,
    message: text,
    user: raw.user as ChatMessageUser | undefined,
    created_at: raw.created_at,
    edited: raw.edited === true,
    deleted_at: raw.deleted_at,
    in_reply_to_id: typeof raw.in_reply_to_id === 'number' ? raw.in_reply_to_id : undefined,
    thread_id: typeof raw.thread_id === 'number' ? raw.thread_id : undefined,
    reactions: reactions.map((r: ChatMessageReactionRaw): ChatMessageReaction => ({
      emoji: r.emoji,
      count: typeof r.count === 'number' ? r.count : undefined,
      usernames: r.usernames
    }))
  };
}

export class ChatService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  // 拉一页消息。before 缺省=最新一页;带 before=往更早翻(历史)。
  async fetchMessages(channelId: number, before?: number): Promise<NetworkResult<ChatMessagesPage>> {
    const params: string[] = ['page_size=50'];
    if (before !== undefined && Number.isFinite(before)) {
      params.push(`target_message_id=${before}`);
      params.push('direction=past');
    }
    const path: string = `/chat/api/channels/${channelId}/messages?${params.join('&')}`;
    const response: NetworkResult<string> = await this.bridge.getJson(path);
    if (!response.success) {
      return forwardFailure<ChatMessagesPage>(response);
    }
    if (response.data === undefined || response.data.length === 0) {
      return unexpectedResponse<ChatMessagesPage>(response.statusCode, response.challengeState,
        '站点聊天消息响应为空。');
    }
    try {
      const payload: ChatMessagesEnvelope = JSON.parse(response.data) as ChatMessagesEnvelope;
      const raws: ChatMessageRaw[] = payload.messages ?? [];
      const messages: ChatMessage[] = [];
      for (let index: number = 0; index < raws.length; index++) {
        const parsed: ChatMessage | undefined = parseChatMessage(raws[index]);
        if (parsed !== undefined) {
          messages.push(parsed);
        }
      }
      // 按消息 id 升序(旧→新)排好再交回页面:UI 统一「历史在上、最新在下」。
      // 服务端可能按 created_at DESC(最新在前)或 ASC 返回,初载/历史页两种方向都有,
      // 这里不看返回顺序、一律按 id 升序,页面再决定 append/prepend,顺序永不依赖端点。
      messages.sort((a: ChatMessage, b: ChatMessage) => a.id - b.id);
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: {
          messages: messages,
          hasMorePast: payload.meta?.can_load_more_past === true
        }
      };
    } catch (error) {
      return unexpectedResponse<ChatMessagesPage>(response.statusCode, response.challengeState,
        '站点聊天消息响应不是有效 JSON。');
    }
  }

  // 发一条消息(乐观 UI):本端先生成 stagedId 暂存气泡,服务端/MessageBus 通过
  // sent 事件里的 staged_id 与本端对齐替换为正式消息。返回 { messageId, stagedId }。
  // stagedId 由调用方(聊天页)传入:乐观气泡与发往服务端的 staged_id 必须同一个,
  // MessageBus sent 事件回传的 staged_id 才能对齐本地暂存消息。缺省回退内部生成。
  async sendMessage(channelId: number, text: string, stagedId?: number): Promise<NetworkResult<ChatSendResult>> {
    const sid: number = stagedId !== undefined && Number.isInteger(stagedId) && stagedId > 0
      ? stagedId : Math.floor(Date.now() % 2000000000);
    // POST /chat/{channelId} 的请求体(官方前端同构:message + staged_id)。
    interface ChatSendBody {
      message: string;
      staged_id: number;
    }
    const payload: ChatSendBody = {
      message: text,
      staged_id: sid
    };
    const body: string = JSON.stringify(payload);
    // 聊天页作 Referer,同源带 cookie + CSRF。
    const referrer: string = `${AppConstants.BASE_URL}/chat/c/${channelId}`;
    const response: NetworkResult<string> = await this.bridge.postJson(`/chat/${channelId}`, body, {
      notifyChallenge: true,
      referrer: referrer
    });
    if (!response.success) {
      return forwardFailure<ChatSendResult>(response);
    }
    if (response.data === undefined || response.data.length === 0) {
      return unexpectedResponse<ChatSendResult>(response.statusCode, response.challengeState,
        '站点发送消息响应为空。');
    }
    try {
      const parsed: ChatSendResponse = JSON.parse(response.data) as ChatSendResponse;
      const messageId: number | undefined = typeof parsed.message_id === 'number' ? parsed.message_id : undefined;
      if (messageId === undefined || messageId <= 0) {
        return unexpectedResponse<ChatSendResult>(response.statusCode, response.challengeState, '站点发送消息响应缺少 message_id。');
      }
      return {
        success: true,
        statusCode: response.statusCode,
        challengeState: response.challengeState,
        data: { messageId: messageId, stagedId: sid }
      };
    } catch (error) {
      return unexpectedResponse<ChatSendResult>(response.statusCode, response.challengeState, '站点发送消息响应不是有效 JSON。');
    }
  }

  // 标记已读:把我读到的位置推到指定消息。聊天页在(重)进页与收到新消息时调用。
  async markRead(channelId: number, messageId: number): Promise<void> {
    if (!Number.isFinite(messageId) || messageId <= 0) {
      return;
    }
    const path: string = `/chat/api/channels/${channelId}/read?message_id=${messageId}`;
    const response: NetworkResult<string> = await this.bridge.putJson(path, {
      referrer: `${AppConstants.BASE_URL}/chat/c/${channelId}`
    });
    if (!response.success) {
      // 已读上报失败不致命:只影响未读角标,下次进页/收消息再补。
      console.info(`${LOG_TAG} markRead failed status=${response.statusCode}`);
    }
  }
}
