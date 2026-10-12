import { NotificationItem } from '../../models/Notification';
import { User } from '../../models/User';
import { RelativeTime } from '../../common/utils/RelativeTime';
import { FaIconDefinition, FaIconView, getFaIcon } from './FaIcon';
import { UserAvatar } from './UserAvatar';
import { BRAND_BLUE, ON_DARK_FG } from '../../common/theme/Palette';
import { CARD_RADIUS } from '../../common/theme/Metrics';

const AVATAR_SIZE: number = 42;
// 头像右下角角标配色:未读=品牌蓝底白图标;已读=白底深灰图标(对齐站点)。
const BADGE_BG_UNREAD: string = BRAND_BLUE;
const BADGE_BG_READ: string = '#FFFFFF';
const BADGE_FG_UNREAD: string = ON_DARK_FG;
const BADGE_FG_READ: string = '#222222';

// 通知列表单行:有发起人 → 头像 + 右下角类型角标;系统类 → 纯色类型图标圈。
// 右侧动作文案(发起人加粗)+ 帖子标题两行、相对时间;未读整行淡蓝底 + 蓝点。
@Component
export struct NotificationListItem {
  item: NotificationItem = {
    id: 0, type: 0, read: true, createdAt: '', actorName: '', actorUsername: '',
    actionText: '', title: '', iconId: 'bell', iconColor: '#9CA3AF'
  };
  onItemClick: (item: NotificationItem) => void = () => {};
  // 卡片模式(飞书/微信式浅灰底+白卡):开圆角、白卡底、卡间留缝;关闭则保持原平面行+分割线。
  cardMode: boolean = false;

  build() {
    Row({ space: 12 }) {
      this.Avatar()

      Column() {
        Text() {
          if (this.item.actorName.length > 0) {
            Span(this.item.actorName)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Span(` ${this.item.actionText}`)
              .fontColor($r('app.color.text_secondary'))
          } else {
            Span(this.item.actionText)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
        }
        .fontSize(15)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.item.title.length > 0) {
          Text(this.item.title)
            .fontSize(13)
            .fontColor(this.item.read ? $r('app.color.text_secondary') : $r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Column({ space: 8 }) {
        Text(RelativeTime.fromNow(this.item.createdAt))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        if (!this.item.read) {
          Circle({ width: 9, height: 9 }).fill($r('app.color.brand'))
        }
      }
      .alignItems(HorizontalAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    // 卡片模式垂直内距取首页(5)与原始(13)的中间档 9:既不像首页帖卡那么密,也不回到原来偏厚。
    // 平面模式沿用原 16 内距不变。
    .padding({ left: this.cardMode ? 12 : 16, right: this.cardMode ? 12 : 16, top: this.cardMode ? 9 : 13, bottom: this.cardMode ? 9 : 13 })
    // 卡片模式:已读=白卡底;未读=淡蓝卡底(未读高亮不能被吃掉)。平面模式沿用原逻辑。
    .backgroundColor(this.cardMode
      ? (this.item.read ? $r('app.color.card_bg') : $r('app.color.info_soft_bg'))
      : (this.item.read ? $r('app.color.page_bg') : $r('app.color.info_soft_bg')))
    .borderRadius(this.cardMode ? CARD_RADIUS : 0)
    // 卡缝取中间档:上下各 3vp(两卡拼出 6vp 整缝),比首页帖卡缝松一些、比原 6/12 紧凑。
    .margin({ top: this.cardMode ? 3 : 0, bottom: this.cardMode ? 3 : 0 })
    .onClick(() => {
      this.onItemClick(this.item);
    })
  }

  @Builder
  private Avatar() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      if (this.item.avatarTemplate !== undefined) {
        // 有发起人:真实头像 + 右下角类型角标。
        UserAvatar({
          user: this.buildActorUser(),
          avatarSize: AVATAR_SIZE
        })
        Stack() {
          FaIconView({
            icon: this.faIcon(this.item.iconId),
            color: this.item.read ? BADGE_FG_READ : BADGE_FG_UNREAD,
            iconSize: 11
          })
        }
        .width(20)
        .height(20)
        .borderRadius(10)
        .backgroundColor(this.item.read ? BADGE_BG_READ : BADGE_BG_UNREAD)
        .alignContent(Alignment.Center)
        .margin({ right: -3, bottom: -3 })
      } else {
        // 系统类:纯色类型图标圈,无角标。
        Stack() {
          FaIconView({ icon: this.faIcon(this.item.iconId), color: '#FFFFFF', iconSize: 18 })
        }
        .width(AVATAR_SIZE)
        .height(AVATAR_SIZE)
        .borderRadius(AVATAR_SIZE / 2)
        .backgroundColor(this.item.iconColor)
        .alignContent(Alignment.Center)
      }
    }
    .width(AVATAR_SIZE)
    .height(AVATAR_SIZE)
  }

  private buildActorUser(): User {
    return {
      id: 0,
      username: this.item.actorUsername.length > 0 ? this.item.actorUsername : '?',
      avatarTemplate: this.item.avatarTemplate
    };
  }

  private faIcon(name: string): FaIconDefinition {
    const def: FaIconDefinition | undefined = getFaIcon(name);
    return def ? def : { id: name, rawfilePath: '' };
  }
}
