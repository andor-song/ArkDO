/**
 * 主题链接的拼装（纯函数，本地 harness 可跑）。
 *
 * 为什么不直接用列表里拿到的 slug 拼死：slug 可能缺（搜索结果 / 推送载荷常常只有 id），
 * 而且站点是运行时可配的 —— 链接必须由**当前站点**派生，不能在别处写死域名。
 */
export function buildTopicUrl(baseUrl: string, slug: string | undefined, topicId: number): string {
  const trimmedHost: string = baseUrl.trim();
  const host: string = trimmedHost.endsWith('/')
    ? trimmedHost.substring(0, trimmedHost.length - 1)
    : trimmedHost;
  if (host.length === 0 || topicId <= 0) {
    return '';
  }
  const hasSlug: boolean = slug !== undefined && slug.trim().length > 0;
  // 有 slug 时用 /t/{slug}/{id}（与网页版一致，可读性更好）；缺 slug 时退回 /t/topic/{id}，
  // 与全仓另外三处「无 slug」拼链接同一形态（PostActions.copyPostLink、CookedHtmlParser、
  // TopicDetailPage.sharePost），也是 TopicService 里十几处 referrer 用的那个页面地址。
  // 两种写法服务端都认，但同一站内不该出现两种形态 —— 复制出去的链接会被贴回站内。
  return hasSlug ? `${host}/t/${slug}/${topicId}` : `${host}/t/topic/${topicId}`;
}

/**
 * 分享文本：标题 + 空行 + 永久链接。
 *
 * 与详情页 sharePost 的三段式（标题 / 正文 / 链接）同构，列表行没有正文可用，
 * 就只留标题与链接。刻意不在这里塞域名或来源水印 —— 收件人要看的是帖子本身。
 */
export function buildTopicShareText(title: string, url: string): string {
  const heading: string = title.trim();
  const link: string = url.trim();
  if (link.length === 0) {
    return heading;
  }
  if (heading.length === 0) {
    return link;
  }
  return `${heading}\n\n${link}`;
}
