import { KeyboardAvoidMode } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import window from '@ohos.window';
import { Log } from '../../services/logging/Log';
import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { ChatMessage, ChatMessageReaction, ChatMessageUser } from '../../models/ChatMessage';
import { User } from '../../models/User';
import { RelativeTime } from '../../common/utils/RelativeTime';
import { ArkWebNetworkBridge } from '../../services/network/ArkWebNetworkBridge';
import {
  ChatMessageRaw,
  ChatService,
  parseChatMessage
} from '../../services/chat/ChatService';
import { MessageBusData, MessageBusEvent, MessageBusEventBus } from '../../services/message/MessageBusEventBus';
import { UserAvatar } from '../components/UserAvatar';
import { SYS_BOTTOM_INSET_KEY, SYS_TOP_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';
import { showToast } from '../../common/utils/Toast';
import { BRAND_BLUE, ON_DARK_FG } from '../../common/theme/Palette';

const LOG_TAG: string = '[ArkDO][ChatPage]';
// 相邻消息时间差小于该值(ms)不重复显示时间行,微信式。
const TIME_GROUP_GAP_MS: number = 5 * 60 * 1000;

// 原生聊天页(Discourse Chat 直聊频道)。
//
// 微信式界面:左右气泡(对方左/自己右)+ 对方头像 + 分组时间 + 底部输入条。
// 数据:
//   - 历史:GET /chat/api/channels/{id}/messages?direction=past(上滑加载更早)
//   - 发送:POST /chat/{id}(乐观 UI:本地暂存→服务端确认 message_id→替换)
//   - 实时收:MessageBus 订阅 /chat/{channel_id}(sent 事件带完整消息对象)
//   - 已读:PUT /chat/api/channels/{id}/read?message_id=
// 全部走现有 ArkWebHost 桥(带 cookie + CSRF,可过 Cloudflare)。
@Component
export struct ChatPage {
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  @StorageProp(SYS_BOTTOM_INSET_KEY) private sysBottomInset: number = 0;
  bridge: ArkWebNetworkBridge | undefined = undefined;
  channelId: number = 0;
  title: string = '';
  // 当前登录用户:用于区分「自己/对方」气泡。由宿主(RootTabPage)注入。
  currentUser?: User = undefined;
  onBack: () => void = () => {};

  @State private messages: ChatMessage[] = [];
  @State private isInitialLoading: boolean = false;
  @State private isLoadingMore: boolean = false;
  @State private hasMorePast: boolean = false;
  @State private loadFailed: boolean = false;
  @State private stateMessage: string = '';
  @State private draft: string = '';
  private service?: ChatService = undefined;
  private loading: boolean = false;
  private scroller: Scroller = new Scroller();
  private unsubscribeMessageBus?: () => void = undefined;
  private didSubscribe: boolean = false;
  // 键盘避让:键盘弹出高度(vp)。窗口常驻全屏,须关掉系统整页避让、自己按键盘高度
  // 上移输入条(对齐本工程 CommentInputBar/ComposerPage 的一致范式)。
  @State private keyboardHeight: number = 0;
  private winClass?: window.Window = undefined;
  private onAvoidAreaChange: (data: window.AvoidAreaOptions) => void = (data: window.AvoidAreaOptions) => {
    if (data.type === window.AvoidAreaType.TYPE_KEYBOARD) {
      const height: number = this.getUIContext().px2vp(data.area.bottomRect.height);
      this.getUIContext().animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.keyboardHeight = height;
      });
    }
  };
  // 历史加载中防止并发。
  private loadingMoreB: boolean = false;
  // 乐观发送中的 stagedId → 防止重复追加(MessageBus sent 回推时)。
  private pendingStagedIds: Set<number> = new Set<number>();

  aboutToAppear(): void {
    if (this.bridge) {
      this.service = new ChatService(this.bridge);
    }
    // 关掉系统默认整页键盘避让,改为自己按键盘高度上移输入条(背后页面不动,对齐 CommentInputBar)。
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.NONE);
    window.getLastWindow(this.getUIContext().getHostContext() as common.Context).then((win: window.Window) => {
      this.winClass = win;
      win.on('avoidAreaChange', this.onAvoidAreaChange);
    }).catch(() => {
      // 拿不到窗口退化为不上移(输入条仍在底部),不影响聊天本身。
    });
    this.subscribeChannel();
    this.loadInitial();
  }

  aboutToDisappear(): void {
    this.unsubscribeChannel();
    if (this.unsubscribeMessageBus) {
      this.unsubscribeMessageBus();
      this.unsubscribeMessageBus = undefined;
    }
    if (this.winClass) {
      this.winClass.off('avoidAreaChange', this.onAvoidAreaChange);
      this.winClass = undefined;
    }
    this.getUIContext().setKeyboardAvoidMode(KeyboardAvoidMode.OFFSET);
  }

  // ==================== MessageBus 实时订阅 ====================

  private subscribeChannel(): void {
    if (!this.bridge || this.didSubscribe || this.channelId <= 0) {
      return;
    }
    this.didSubscribe = true;
    // 订阅 /chat/{channelId}:position=-1 只收新消息,旧消息由历史接口补。
    this.bridge.subscribeChannel(`/chat/${this.channelId}`, -1);
    if (!this.unsubscribeMessageBus) {
      this.unsubscribeMessageBus = MessageBusEventBus.subscribe((event: MessageBusEvent) => {
        this.handleMessageBusEvent(event);
      });
    }
  }

  private unsubscribeChannel(): void {
    if (this.bridge && this.didSubscribe) {
      this.bridge.unsubscribeChannel(`/chat/${this.channelId}`);
      this.didSubscribe = false;
    }
  }

  // 只认本频道的 sent 事件:新消息追加 / 自己发的 optimistic 替换。
  private handleMessageBusEvent(event: MessageBusEvent): void {
    if (event.type !== 'message' || event.channel !== `/chat/${this.channelId}`) {
      return;
    }
    if (!event.data || typeof event.data !== 'object') {
      return;
    }
    const record: MessageBusData = event.data;
    const chatRaw: ChatMessageRaw | undefined = record.chat_message as ChatMessageRaw | undefined;
    if (!chatRaw) {
      return;
    }
    const parsed: ChatMessage | undefined = parseChatMessage(chatRaw);
    if (parsed === undefined) {
      return;
    }
    // sent 事件可能带 staged_id(官方前端即用它在本地把「临时气泡」替换成服务端消息)。
    // 若对应本端一个乐观气泡,把它原位替换,绝不追加,避免 POST 响应与 sent 事件乱序造成的重复。
    const staged: number = typeof record.staged_id === 'number' ? record.staged_id : -1;
    if (staged > 0 && this.pendingStagedIds.has(staged)) {
      const idx: number = this.findPendingIndex(staged);
      if (idx >= 0) {
        const copy: ChatMessage[] = this.messages.slice();
        copy[idx] = parsed;
        this.messages = copy;
      }
      this.pendingStagedIds.delete(staged);
      this.markReadTo(parsed.id);
      return;
    }
    // 已存在(编辑/删除/重复回推)则按 id 幂等更新,不重复追加。
    const existingIndex: number = this.messages.findIndex((m: ChatMessage) => m.id === parsed.id);
    if (existingIndex >= 0) {
      const merged: ChatMessage = this.cloneMessage(parsed);
      merged.pending = false;
      const copy: ChatMessage[] = this.messages.slice();
      copy[existingIndex] = merged;
      this.messages = copy;
      return;
    }
    // 新消息(自己或对方):追加到底部。
    this.messages = this.messages.concat([parsed]);
    this.pendingStagedIds.delete(parsed.stagedId ?? -1);
    // 自己发的 sent 回推:/chat/{id} 频道也会推给发送者,标记已读到最新。
    if (parsed.user !== undefined && this.currentUser !== undefined &&
      parsed.user.id === this.currentUser.id) {
      this.markReadTo(parsed.id);
      return;
    }
    // 对方消息:已读上报 + 滚到底(若用户本就贴在底部)。
    this.markReadTo(parsed.id);
    this.scrollToBottomIfAtEnd();
  }

  // ==================== 数据加载 ====================

  private async loadInitial(): Promise<void> {
    if (!this.service || this.loading || this.channelId <= 0) {
      return;
    }
    this.loading = true;
    this.isInitialLoading = true;
    this.loadFailed = false;
    this.stateMessage = '';

    const result = await this.service.fetchMessages(this.channelId);
    this.loading = false;
    this.isInitialLoading = false;

    if (!result.success || result.data === undefined) {
      this.loadFailed = true;
      this.stateMessage = result.error?.message ? result.error.message : '加载失败，请重试';
      Log.i(`${LOG_TAG} initial load failed status=${result.statusCode}`);
      return;
    }
    this.messages = result.data.messages;
    this.hasMorePast = result.data.hasMorePast;
    // 标记已读到最新一条(重进聊天视为已读)。
    const last: ChatMessage | undefined = this.messages.length > 0
      ? this.messages[this.messages.length - 1] : undefined;
    if (last !== undefined) {
      this.markReadTo(last.id);
    }
    Log.i(`${LOG_TAG} initial loaded count=${this.messages.length} hasMore=${this.hasMorePast}`);
    // 首屏落到底部(最新消息)。
    if (this.messages.length > 0) {
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 80);
    }
  }

  // 上滑到顶加载更早历史:prepend 到列表,保持原首条位置。
  private async loadMorePast(): Promise<void> {
    if (!this.service || this.loadingMoreB || !this.hasMorePast || this.messages.length === 0) {
      return;
    }
    this.loadingMoreB = true;
    this.isLoadingMore = true;
    const before: number = this.messages[0].id;
    const result = await this.service.fetchMessages(this.channelId, before);
    this.loadingMoreB = false;
    this.isLoadingMore = false;

    if (!result.success || result.data === undefined || result.data.messages.length === 0) {
      this.hasMorePast = false;
      return;
    }
    // 去重(与已加载的尾部可能有交叠)。
    const existingIds: Set<number> = new Set<number>();
    for (let i: number = 0; i < this.messages.length; i++) {
      existingIds.add(this.messages[i].id);
    }
    const older: ChatMessage[] = [];
    for (let i: number = 0; i < result.data.messages.length; i++) {
      const m: ChatMessage = result.data.messages[i];
      if (!existingIds.has(m.id)) {
        older.push(m);
      }
    }
    if (older.length === 0) {
      this.hasMorePast = false;
      return;
    }
    this.messages = older.concat(this.messages);
    this.hasMorePast = result.data.hasMorePast;
    // 把原首条顶回顶部,避免视口跳走。
    // List 前两个 ListItem 是固定占位(spacer=0, 加载指示=1),消息项从 index 2 起；
    // prepend 了 older.length 条后,原首条(此前位于列表 index=2)现在位于 index=2+older.length。
    const keepFirstAtIndex: number = 2 + older.length;
    setTimeout(() => {
      this.scroller.scrollToIndex(keepFirstAtIndex, false, ScrollAlign.START);
    }, 50);
  }

  // ==================== 发送(乐观 UI) ====================

  private submitDraft(): void {
    const text: string = this.draft.trim();
    if (text.length === 0 || !this.service) {
      return;
    }
    // 先清空输入框,避免发送中重复点。
    this.draft = '';
    const stagedUser: ChatMessageUser | undefined = this.currentUser ? {
      id: this.currentUser.id,
      username: this.currentUser.username,
      name: this.currentUser.displayName,
      avatar_template: this.currentUser.avatarTemplate
    } : undefined;
    const optimistic: ChatMessage = {
      id: -Date.now(),
      message: text,
      user: stagedUser,
      created_at: new Date().toISOString(),
      pending: true,
      stagedId: -1
    };
    const stagedId: number = Math.floor(Math.random() * 2000000000);
    optimistic.stagedId = stagedId;
    this.pendingStagedIds.add(stagedId);
    this.messages = this.messages.concat([optimistic]);
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 40);

    // stagedId 与乐观气泡保持一致:服务端送回 sent 事件的 staged_id 才能命中替换。
    this.service.sendMessage(this.channelId, text, stagedId).then((result) => {
      if (!result.success || result.data === undefined) {
        // 发送失败:把该条标失败(红感叹),保留内容便于重发。
        const idx: number = this.findPendingIndex(stagedId);
        if (idx >= 0) {
          const copy: ChatMessage[] = this.messages.slice();
          const failedCopy: ChatMessage = this.cloneMessage(copy[idx]);
          failedCopy.pending = false;
          failedCopy.failed = true;
          copy[idx] = failedCopy;
          this.messages = copy;
        }
        this.pendingStagedIds.delete(stagedId);
        showToast(this.getUIContext(), result.error?.message ? result.error.message : '发送失败', 1800);
        return;
      }
      // 成功:替换为服务端正式消息(pending=false)。MessageBus sent 事件随后幂等去重。
      const idx: number = this.findPendingIndex(stagedId);
      if (idx >= 0) {
        const formal: ChatMessage = {
          id: result.data.messageId,
          message: text,
          user: stagedUser,
          created_at: new Date().toISOString(),
          pending: false
        };
        const copy: ChatMessage[] = this.messages.slice();
        copy[idx] = formal;
        this.messages = copy;
        this.markReadTo(formal.id);
      }
      this.pendingStagedIds.delete(stagedId);
    });
  }

  // 复制一条消息对象(ArkTS 不允许 spread 对象字面量,合并字段时用它)。
  private cloneMessage(src: ChatMessage): ChatMessage {
    const dest: ChatMessage = {
      id: src.id,
      message: src.message,
      user: src.user,
      created_at: src.created_at,
      edited: src.edited,
      deleted_at: src.deleted_at,
      in_reply_to_id: src.in_reply_to_id,
      thread_id: src.thread_id,
      reactions: src.reactions,
      id_cursor: src.id_cursor,
      pending: src.pending,
      stagedId: src.stagedId,
      failed: src.failed
    };
    return dest;
  }

  private findPendingIndex(stagedId: number): number {
    for (let i: number = 0; i < this.messages.length; i++) {
      if (this.messages[i].pending === true && this.messages[i].stagedId === stagedId) {
        return i;
      }
    }
    return -1;
  }

  // 指到一条消息为已读(服务端记录 last_read_message_id)。
  private markReadTo(messageId: number): void {
    if (!this.service || messageId <= 0) {
      return;
    }
    this.service.markRead(this.channelId, messageId);
  }

  // 收到对方新消息时,若用户本就贴着底部才滚动,否则不动(避免抢视线)。
  private scrollToBottomIfAtEnd(): void {
    // MVP:直接滚到底。更精细的「贴近才滚」需要 onScrollIndex 跟踪,先保持简单。
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
  }

  // ==================== UI ====================

  build() {
    HdsNavigation() {
      Column() {
        if (this.messages.length === 0) {
          Column() {
            if (this.isInitialLoading) {
              LoadingProgress()
                .width(36)
                .height(36)
            } else if (this.loadFailed) {
              Text(this.stateMessage.length > 0 ? this.stateMessage : '加载失败')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Button('重试')
                .margin({ top: 12 })
                .onClick(() => {
                  this.loadInitial();
                })
            } else {
              Text('还没有消息')
                .fontSize(14)
                .fontColor($r('app.color.text_tertiary'))
            }
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List({ scroller: this.scroller }) {
            // 上滑到顶 → 加载更早历史。
            // 用 ListItem+height(0) 作为顶部探针:到达列表顶点触发 onReachStart。
            // 沉浸式标题栏占位:首项从标题栏下方开始(同 MessageInboxPage 的 TitleBarListHeader)。
            ListItem() {
              Column() {
                Blank()
                  .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))
              }
              .width('100%')
            }

            ListItem() {
              Row() {
                if (this.isLoadingMore) {
                  LoadingProgress()
                    .width(18)
                    .height(18)
                    .margin({ top: 10, bottom: 2 })
                } else if (this.hasMorePast) {
                  Text('上滑加载更早')
                    .fontSize(12)
                    .fontColor($r('app.color.text_tertiary'))
                    .margin({ top: 8, bottom: 2 })
                }
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
            }

            ForEach(this.messages, (item: ChatMessage, index: number) => {
              ListItem() {
                this.MessageRow(item, index)
              }
            }, (item: ChatMessage, index: number) => {
              const keyBase: string = item.pending === true && item.stagedId !== undefined
                ? `pending_${item.stagedId}` : `msg_${item.id}`;
              return `${keyBase}_${index}`;
            })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .onReachStart(() => {
            this.loadMorePast();
          })
        }

        this.ChatInput()
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_bg_gray'))
    }
    .titleBar({
      avoidLayoutSafeArea: requiresHdsLayoutSafeAreaAvoidance(ImmersiveLightArea.TITLE_BAR),
      enableComponentSafeArea: requiresHdsComponentSafeArea(ImmersiveLightArea.TITLE_BAR),
      style: buildImmersiveTitleBarStyle({}),
      content: {
        title: {
          mainTitle: this.title.length > 0 ? this.title : '聊天'
        },
        backIcon: {
          icon: $r('sys.symbol.chevron_left'),
          label: '返回',
          action: () => {
            this.onBack();
          }
        }
      }
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_bg_gray'))
  }

  // ==================== 底部输入条 ====================

  @Builder
  private ChatInput() {
    Row({ space: 8 }) {
      TextArea({
        text: $$this.draft,
        placeholder: '发消息…'
      })
        .width('100%')
        .layoutWeight(1)
        .backgroundColor($r('app.color.immersive_input_field_bg'))
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_tertiary'))
        .constraintSize({ minHeight: 40, maxHeight: 110 })
        .enterKeyType(EnterKeyType.NEW_LINE)
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .onChange((value: string) => {
          this.draft = value;
        })

      Button({ type: ButtonType.Circle, stateEffect: true }) {
        // 发送中态由乐观消息自身表示,这里固定显示发送图标;可发送时高亮,否则降透明。
        SymbolGlyph($r('sys.symbol.paperplane_fill'))
          .fontSize(18)
          .fontColor([ON_DARK_FG])
      }
      .width(40)
      .height(40)
      .backgroundColor(BRAND_BLUE)
      .opacity(this.canSend() ? 1 : 0.5)
      .onClick(() => {
        this.submitDraft();
      })
    }
    .width('100%')
    .padding({ left: 10, right: 10, top: 8, bottom: 8 + (this.keyboardHeight > 0 ? this.keyboardHeight : this.sysBottomInset) })
    .backgroundColor($r('app.color.immersive_input_bar_bg'))
  }

  private canSend(): boolean {
    return this.draft.trim().length > 0;
  }

  // ==================== 消息行 ====================

  @Builder
  private MessageRow(item: ChatMessage, index: number) {
    Column() {
      // 分组时间:与上一条超过 5 分钟才显示。
      if (this.shouldShowTime(index)) {
        Text(item.created_at !== undefined ? RelativeTime.fromNow(item.created_at) : '')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .margin({ top: 12, bottom: 4 })
          .textAlign(TextAlign.Center)
          .width('100%')
      }

      Row() {
        // 对方(非自己)消息:左侧头像。
        if (!this.isMine(item)) {
          UserAvatar({ user: this.peerUser(item), avatarSize: 34 })
            .margin({ right: 8 })
        }

        Column() {
          if (this.isMine(item)) {
            this.MineBubble(item, index)
          } else {
            this.PeerBubble(item, index)
          }
        }
        .alignItems(this.isMine(item) ? HorizontalAlign.End : HorizontalAlign.Start)

        // 自己消息:右侧头像。
        if (this.isMine(item)) {
          this.avatarOfSelf()
        }
      }
      .width('100%')
      .justifyContent(this.isMine(item) ? FlexAlign.End : FlexAlign.Start)
      .alignItems(VerticalAlign.Top)
      .margin({ top: 2, bottom: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private MineBubble(item: ChatMessage, index: number) {
    Column({ space: 3 }) {
      Text(item.message)
        .fontSize(15)
        .fontColor(ON_DARK_FG)
        .lineHeight(20)
        .copyOption(CopyOptions.LocalDevice)
      Row() {
        if (item.pending === true) {
          LoadingProgress()
            .width(12)
            .height(12)
            .color(ON_DARK_FG)
            .margin({ right: 4 })
          Text('发送中')
            .fontSize(10)
            .fontColor(ON_DARK_FG)
        } else if (item.failed === true) {
          Text('未送达')
            .fontSize(10)
            .fontColor(ON_DARK_FG)
        } else {
          Text(item.created_at !== undefined ? RelativeTime.fromNow(item.created_at) : '')
            .fontSize(10)
            .fontColor(ON_DARK_FG)
        }
      }
    }
    .constraintSize({ maxWidth: '62%' })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor(BRAND_BLUE)
    .borderRadius(16)
  }

  @Builder
  private PeerBubble(item: ChatMessage, index: number) {
    Column({ space: 3 }) {
      Text(item.message)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(20)
        .copyOption(CopyOptions.LocalDevice)
      if (item.reactions !== undefined && item.reactions.length > 0) {
        Row({ space: 6 }) {
          ForEach(item.reactions, (r: ChatMessageReaction) => {
            if (r.emoji && r.count) {
              Text(`${r.emoji} ${r.count}`)
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
            }
          }, (r: ChatMessageReaction, ri: number) => `react_${item.id}_${ri}`)
        }
      }
    }
    .constraintSize({ maxWidth: '62%' })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.card_bg'))
    .borderRadius(16)
  }

  @Builder
  private avatarOfSelf() {
    UserAvatar({ user: this.currentUser, avatarSize: 34 })
      .margin({ left: 8 })
  }

  // 对方头像(消息自带头像;缺则用当前用户占位,不乱)。
  private peerUser(item: ChatMessage): User {
    const u: ChatMessageUser | undefined = item.user;
    if (u !== undefined && u.id !== undefined && (this.currentUser === undefined || u.id !== this.currentUser.id)) {
      return {
        id: u.id,
        username: u.username ?? '',
        displayName: u.name,
        avatarTemplate: u.avatar_template
      };
    }
    if (this.currentUser !== undefined) {
      return this.currentUser;
    }
    return { id: 0, username: '', displayName: '?' };
  }

  private isMine(item: ChatMessage): boolean {
    if (this.currentUser === undefined) {
      return false;
    }
    if (item.pending === true && item.stagedId !== undefined) {
      return true;
    }
    const u: ChatMessageUser | undefined = item.user;
    return u !== undefined && u.id === this.currentUser.id;
  }

  // 与上一条消息相隔超过 TIME_GROUP_GAP_MS 才显示时间行;首条也显示。
  private shouldShowTime(index: number): boolean {
    const item: ChatMessage = this.messages[index];
    if (item.created_at === undefined) {
      return false;
    }
    if (index <= 0) {
      return true;
    }
    const prev: ChatMessage = this.messages[index - 1];
    if (prev.created_at === undefined) {
      return true;
    }
    const a: number = new Date(item.created_at).getTime();
    const b: number = new Date(prev.created_at).getTime();
    if (isNaN(a) || isNaN(b)) {
      return false;
    }
    return Math.abs(a - b) >= TIME_GROUP_GAP_MS;
  }
}
