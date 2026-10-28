import { User } from '../../models/User';
import { JsonNetworkClient, NetworkResult } from '../../services/network/NetworkTypes';
import { friendlyFailure, rawFailure } from '../../services/network/UserFacingError';
import { UserCard, UserCardService } from '../../services/user/UserCardService';
import { LoginGate } from '../../services/session/LoginGate';
import { Log } from '../../services/logging/Log';
import { UserAvatar } from './UserAvatar';
import { showToast, TOAST_SHORT_MS } from '../../common/utils/Toast';
import { SYS_BOTTOM_INSET_KEY } from '../../common/utils/ImmersiveWindow';
import { SCRIM_STRONG } from '../../common/theme/Palette';

const LOG_TAG: string = '[ArkDO][UserCard]';

/**
 * 用户卡片浮层:点头像弹出「简介 + 统计 + 关注」,再决定要不要进主页。
 *
 * 数据来自 /u/{username}/card.json(can_follow / is_followed 只在这个序列化器里)。
 * 首屏用点击时已有的昵称/头像先画出来,不等网络 —— 弹层先出现、内容再补,比转圈等着更像原生。
 *
 * 私信入口不放在这里:发私信要正文编辑器,而编辑器的私信模式长在个人主页里
 * (UserProfilePage 的内联 composer)。在卡片里再开一套就是两条分叉的发送链路。
 */
@Component
export struct UserCardOverlay {
  @StorageProp(SYS_BOTTOM_INSET_KEY) private sysBottomInset: number = 0;
  bridge: JsonNetworkClient | undefined = undefined;
  username: string = '';
  seedName: string = '';
  seedAvatarTemplate: string = '';
  onClose: () => void = () => {};
  onOpenProfile: (username: string) => void = () => {};

  @State private card: UserCard | undefined = undefined;
  @State private loading: boolean = true;
  @State private error: string = '';
  @State private followSaving: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    if (bridge === undefined) {
      this.loading = false;
      this.error = '正在准备请求环境';
      return;
    }
    this.loading = true;
    this.error = '';
    const result: NetworkResult<UserCard> = await new UserCardService(bridge).load(this.username);
    this.loading = false;
    if (!result.success || result.data === undefined) {
      this.error = friendlyFailure(result, { subject: '用户卡片', action: '加载' });
      Log.i(`${LOG_TAG} load failed user=${this.username} ${rawFailure(result)}`);
      return;
    }
    this.card = result.data;
  }

  private displayName(): string {
    if (this.card !== undefined && this.card.name !== undefined) {
      return this.card.name;
    }
    return this.seedName.length > 0 ? this.seedName : this.username;
  }

  private avatarTemplate(): string | undefined {
    if (this.card !== undefined && this.card.avatarTemplate !== undefined) {
      return this.card.avatarTemplate;
    }
    return this.seedAvatarTemplate.length > 0 ? this.seedAvatarTemplate : undefined;
  }

  private seedUser(): User {
    return { id: 0, username: this.username, displayName: this.displayName(), avatarTemplate: this.avatarTemplate() };
  }

  private async toggleFollow(): Promise<void> {
    const bridge: JsonNetworkClient | undefined = this.bridge;
    const card: UserCard | undefined = this.card;
    if (bridge === undefined || card === undefined || this.followSaving) {
      return;
    }
    if (!LoginGate.ensureLoggedIn()) {
      return;
    }
    const next: boolean = !card.isFollowed;
    this.followSaving = true;
    const result: NetworkResult<boolean> = await new UserCardService(bridge).setFollow(card.username, next);
    this.followSaving = false;
    if (!result.success) {
      showToast(this.getUIContext(), friendlyFailure(result, { subject: '关注', action: next ? '添加' : '取消' }),
        2000);
      Log.i(`${LOG_TAG} follow failed user=${card.username} next=${next} ${rawFailure(result)}`);
      return;
    }
    // 就地翻转:关注数跟着 ±1,但不要低于 0。
    this.card = {
      username: card.username, name: card.name, avatarTemplate: card.avatarTemplate,
      bioExcerpt: card.bioExcerpt, postCount: card.postCount, topicCount: card.topicCount,
      likesReceived: card.likesReceived,
      totalFollowers: Math.max(0, card.totalFollowers + (next ? 1 : -1)),
      totalFollowing: card.totalFollowing,
      canFollow: card.canFollow, isFollowed: next, canSendPrivateMessage: card.canSendPrivateMessage
    };
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(SCRIM_STRONG)
        .onClick(() => {
          this.onClose();
        })

      Column() {
        Row() {
          UserAvatar({ user: this.seedUser(), avatarSize: 52 })
          Column() {
            Text(this.displayName())
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(`@${this.username}`)
              .fontSize(12)
              .fontColor($r('app.color.text_faint'))
              .margin({ top: 2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
          .margin({ left: 12 })
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 18 })

        if (this.loading) {
          Row() {
            LoadingProgress().width(18).height(18).color($r('app.color.ld_accent'))
          }
          .padding({ top: 16 })
        } else if (this.error.length > 0) {
          Text(this.error)
            .fontSize(13)
            .fontColor($r('app.color.warning'))
            .width('100%')
            .padding({ left: 20, right: 20, top: 14 })
        } else if (this.card !== undefined) {
          if (this.card.bioExcerpt.length > 0) {
            Text(this.card.bioExcerpt)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .padding({ left: 20, right: 20, top: 12 })
          }
          Row() {
            this.StatCell('帖子', this.card.postCount)
            this.StatCell('主题', this.card.topicCount)
            this.StatCell('获赞', this.card.likesReceived)
            this.StatCell('关注者', this.card.totalFollowers)
          }
          .width('100%')
          .padding({ left: 20, right: 20, top: 14 })
        }

        Row() {
          Button('查看主页')
            .height(40)
            .fontSize(15)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.surface_muted'))
            .borderRadius(20)
            .layoutWeight(1)
            .onClick(() => {
              this.onClose();
              this.onOpenProfile(this.username);
            })
          if (this.card !== undefined && this.card.canFollow) {
            Button(this.card.isFollowed ? '已关注' : '关注')
              .height(40)
              .fontSize(15)
              .fontColor(this.card.isFollowed ? $r('app.color.text_secondary') : Color.White)
              .backgroundColor(this.card.isFollowed ? $r('app.color.surface_muted') : $r('app.color.brand'))
              .borderRadius(20)
              .layoutWeight(1)
              .margin({ left: 10 })
              .enabled(!this.followSaving)
              .onClick(() => {
                this.toggleFollow();
              })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 18, bottom: this.sysBottomInset + 16 })
      }
      .width('100%')
      .backgroundColor($r('app.color.page_bg'))
      .borderRadius({ topLeft: 20, topRight: 20 })
      .clip(true)
      .transition(TransitionEffect.move(TransitionEdge.BOTTOM).combine(TransitionEffect.OPACITY)
        .animation({ duration: 240, curve: Curve.EaseOut }))
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: 200, curve: Curve.EaseOut }))
  }

  @Builder
  private StatCell(label: string, value: number) {
    Column() {
      Text(`${value}`)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text(label)
        .fontSize(11)
        .fontColor($r('app.color.text_faint'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }
}
