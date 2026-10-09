// 分页列表的尾行:加载中转圈 + 「上拉加载更多 / 没有更多了」。
//
// 抽取前这 17 行在 6 个分页页面里逐字复制(其中 5 份完全一致)。
//
// isLoading / hasMore 必须是 @Prop:普通成员只在构造时赋值一次,父页翻 @State 时
// 尾行不会重绘——转圈会一直转下去、"没有更多了"也永远不出现。
//
// 首页/详情页的尾行文案在运行期会变(「刷新失败，请重试」「正在准备 ArkWeb 请求环境」等),
// 因此 message 也走 @Prop:不传时按 hasMore 显示默认文案,传了就用运行期文案。
@Component
export struct ListFooter {
  @Prop isLoading: boolean = false;
  @Prop hasMore: boolean = true;
  // 到底时的文案。通知页历史上用的是「已到底」,与其余页不同;
  // 属用户可见文案,抽取时原样保留,未擅自统一。
  endText: string = '没有更多了';
  // 运行期覆盖文案(首页刷新失败/准备环境等非「加载中/到底」态)。
  @Prop message: string = '';
  accentColor: Resource = $r('app.color.brand');
  textColor: Resource = $r('app.color.text_faint');
  // 加载失败/访问验证等需要警示色时,覆盖默认灰字(首页挑战态用 warning 色)。
  messageColor: Resource = $r('app.color.text_faint');

  build() {
    Row() {
      if (this.isLoading) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(this.accentColor)
          .margin({ right: 8 })
      }
      Text(this.displayMessage())
        .fontSize(13)
        // message 是运行期覆盖文案(首页刷新失败等),用 messageColor 单独着色;
        // 无 message 的常规尾行沿用 textColor(各页可传 text_secondary/text_tertiary 等)。
        .fontColor(this.message.length > 0 ? this.messageColor : this.textColor)
    }
    .width('100%')
    .height(54)
    .justifyContent(FlexAlign.Center)
  }

  private displayMessage(): string {
    if (this.message.length > 0) {
      return this.message;
    }
    return this.hasMore ? '上拉加载更多' : this.endText;
  }
}
