import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { User } from '../../models/User';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { friendlyFailure, rawFailure } from '../../services/network/UserFacingError';
import { UserProfileService } from '../../services/user/UserProfileService';
import { CreateTopicOutcome, TopicService } from '../../services/topic/TopicService';
import { LoginGate } from '../../services/session/LoginGate';
import { Log } from '../../services/logging/Log';
import { ChoiceChip } from '../components/ChoiceChip';
import { showToast, TOAST_SHORT_MS } from '../../common/utils/Toast';
import { SYS_TOP_INSET_KEY, SYS_BOTTOM_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { immersiveTitleBarContentTopSpacer } from '../../common/ui/ImmersiveTitleBarLayout';
import {
  ImmersiveLightArea,
  requiresHdsComponentSafeArea,
  requiresHdsLayoutSafeAreaAvoidance
} from '../../common/ui/ImmersiveLightMaterial';
import { buildImmersiveTitleBarStyle } from '../../common/ui/ImmersiveTitleBarStyle';

const LOG_TAG: string = '[ArkDO][PmCompose]';
const USER_SEARCH_LIMIT: number = 8;
const SEARCH_DEBOUNCE_MS: number = 280;

/**
 * 新建私信(支持多人)。
 *
 * 与个人主页的内联私信 composer 的关系:那条链路是「已经知道发给谁」的一对一快捷入口,
 * 收件人由页面决定;这里是「收件人自己填」的通用新建,支持多人。
 * 两者最终都走同一个 TopicService.createPrivateMessage(archetype=private_message),
 * 不另造发送协议。
 *
 * 收件人联想复用 /u/search/users(与全局搜索的用户页同一接口),但**不强制**从联想里选:
 * 手输一个完整用户名也能加 —— 联想接口对隐私设置敏感的用户可能查不到,强制选人会卡住正常发送。
 */
@Component
export struct PrivateMessageComposePage {
  @StorageProp(SYS_TOP_INSET_KEY) private sysTopInset: number = 0;
  @StorageProp(SYS_BOTTOM_INSET_KEY) private sysBottomInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  // 从用户主页/卡片进入时预填的收件人(单人)。为空就是全新私信。
  initialRecipient: string = '';
  onBack: () => void = () => {};

  @State private recipients: string[] = [];
  @State private recipientInput: string = '';
  @State private suggestions: User[] = [];
  @State private title: string = '';
  @State private body: string = '';
  @State private sending: boolean = false;
  private searchTimer: number = -1;
  // 联想请求序号:丢弃过期响应(边打字边搜,后发先至会把旧结果盖上来)。
  private searchSeq: number = 0;

  aboutToAppear(): void {
    const seed: string = this.initialRecipient.trim();
    if (seed.length > 0) {
      this.recipients = [seed];
    }
  }

  aboutToDisappear(): void {
    this.clearSearchTimer();
  }

  private clearSearchTimer(): void {
    if (this.searchTimer >= 0) {
      clearTimeout(this.searchTimer);
      this.searchTimer = -1;
    }
  }

  private addRecipient(username: string): void {
    const name: string = username.trim().replace(/^@/, '');
    if (name.length === 0) {
      return;
    }
    if (this.recipients.indexOf(name) >= 0) {
      this.recipientInput = '';
      return;
    }
    const next: string[] = this.recipients.slice();
    next.push(name);
    this.recipients = next;
    this.recipientInput = '';
    this.suggestions = [];
  }

  private removeRecipient(username: string): void {
    const next: string[] = [];
    for (let index: number = 0; index < this.recipients.length; index++) {
      if (this.recipients[index] !== username) {
        next.push(this.recipients[index]);
      }
    }
    this.recipients = next;
  }

  private onRecipientInputChanged(value: string): void {
    this.recipientInput = value;
    this.clearSearchTimer();
    const term: string = value.trim().replace(/^@/, '');
    if (term.length === 0) {
      this.suggestions = [];
      return;
    }
    this.searchTimer = setTimeout(() => {
      this.searchTimer = -1;
      this.searchUsers(term);
    }, SEARCH_DEBOUNCE_MS);
  }

  private async searchUsers(term: string): Promise<void> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined) {
      return;
    }
    this.searchSeq++;
    const seq: number = this.searchSeq;
    const result: NetworkResult<User[]> =
      await new UserProfileService(bridge).searchUsers(term, USER_SEARCH_LIMIT);
    if (seq !== this.searchSeq) {
      return;
    }
    if (!result.success || result.data === undefined) {
      // 联想失败不打断输入:手输完整用户名仍可添加。
      this.suggestions = [];
      return;
    }
    this.suggestions = result.data;
  }

  private async send(): Promise<void> {
    if (this.sending) {
      return;
    }
    if (!LoginGate.ensureLoggedIn()) {
      return;
    }
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined) {
      showToast(this.getUIContext(), '正在准备请求环境，请稍后重试', TOAST_SHORT_MS);
      return;
    }
    if (this.recipients.length === 0) {
      showToast(this.getUIContext(), '请先添加收件人', TOAST_SHORT_MS);
      return;
    }
    const raw: string = this.body.trim();
    if (raw.length === 0) {
      showToast(this.getUIContext(), '写点内容再发送', TOAST_SHORT_MS);
      return;
    }
    this.sending = true;
    const result: NetworkResult<CreateTopicOutcome> = await new TopicService(bridge)
      .createPrivateMessage(this.recipients, raw, this.title.trim());
    this.sending = false;
    if (!result.success) {
      showToast(this.getUIContext(), friendlyFailure(result, { subject: '私信', action: '发送' }), 2500);
      Log.i(`${LOG_TAG} send failed recipients=${this.recipients.join(',')} ${rawFailure(result)}`);
      return;
    }
    showToast(this.getUIContext(), '私信已发送', TOAST_SHORT_MS);
    this.onBack();
  }

  build() {
    HdsNavigation() {
      this.Content()
    }
    .titleBar({
      avoidLayoutSafeArea: requiresHdsLayoutSafeAreaAvoidance(ImmersiveLightArea.TITLE_BAR),
      enableComponentSafeArea: requiresHdsComponentSafeArea(ImmersiveLightArea.TITLE_BAR),
      style: buildImmersiveTitleBarStyle({ enableRefreshOffsetChange: false }),
      content: {
        title: {
          mainTitle: '新建私信'
        },
        backIcon: {
          icon: $r('sys.symbol.chevron_left'),
          label: '返回',
          action: () => {
            this.onBack();
          }
        },
        menu: {
          value: [{
            content: {
              icon: $r('sys.symbol.paperplane'),
              label: '发送',
              isEnabled: !this.sending,
              action: () => {
                this.send();
              }
            }
          }]
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

  @Builder
  private Content() {
    Scroll() {
      Column() {
        Blank()
          .height(immersiveTitleBarContentTopSpacer(this.sysTopInset))

        // ===== 收件人 =====
        Column() {
          Text('收件人')
            .fontSize(12)
            .fontColor($r('app.color.text_faint'))
            .width('100%')

          if (this.recipients.length > 0) {
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.recipients, (name: string) => {
                ChoiceChip({
                  label: name,
                  removable: true,
                  compact: true,
                  onTap: () => {
                    this.removeRecipient(name);
                  }
                })
              }, (name: string) => `r${name}`)
            }
            .width('100%')
            .margin({ top: 6 })
          }

          Row() {
            TextInput({ text: $$this.recipientInput, placeholder: '用户名（可多人，逐个添加）' })
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.surface_muted'))
              .borderRadius(10)
              .layoutWeight(1)
              .onChange((value: string) => {
                this.onRecipientInputChanged(value);
              })
              .onSubmit(() => {
                this.addRecipient(this.recipientInput);
              })
            Button('添加')
              .height(36)
              .fontSize(14)
              .fontColor(Color.White)
              .backgroundColor($r('app.color.brand'))
              .borderRadius(18)
              .margin({ left: 8 })
              .enabled(this.recipientInput.trim().length > 0)
              .onClick(() => {
                this.addRecipient(this.recipientInput);
              })
          }
          .width('100%')
          .margin({ top: 6 })

          // 联想结果:点一下加入。不强制从这里选 —— 手输完整用户名同样有效。
          if (this.suggestions.length > 0) {
            Column() {
              ForEach(this.suggestions, (user: User) => {
                Row() {
                  Text(user.displayName !== undefined && user.displayName.length > 0
                    ? `${user.displayName} (@${user.username})` : `@${user.username}`)
                    .fontSize(14)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('添加')
                    .fontSize(12)
                    .fontColor($r('app.color.brand'))
                }
                .width('100%')
                .padding({ top: 8, bottom: 8 })
                .onClick(() => {
                  this.addRecipient(user.username);
                })
              }, (user: User) => `s${user.id}_${user.username}`)
            }
            .width('100%')
            .margin({ top: 6 })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        .backgroundColor($r('app.color.card_bg'))
        .borderRadius(12)
        .margin({ left: 12, right: 12 })

        // ===== 标题(可选) =====
        TextInput({ text: $$this.title, placeholder: '标题（可选）' })
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)
          .margin({ left: 12, right: 12, top: 10 })

        // ===== 正文 =====
        TextArea({ text: $$this.body, placeholder: '写点什么…' })
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
          .backgroundColor($r('app.color.card_bg'))
          .borderRadius(12)
          .height(240)
          .margin({ left: 12, right: 12, top: 10 })

        Button(this.sending ? '发送中…' : '发送')
          .width('calc(100% - 24vp)')
          .height(44)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor($r('app.color.brand'))
          .borderRadius(22)
          .margin({ left: 12, right: 12, top: 14 })
          .enabled(!this.sending)
          .onClick(() => {
            this.send();
          })

        Row()
          .height(this.sysBottomInset + 24)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
