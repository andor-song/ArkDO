/**
 * 从 cooked HTML 里收集帖子配图(纯函数,本地 harness 可跑)。
 *
 * 为什么不用 CookedHtmlParser:图片墙只需要「有哪些图」,不需要排版结构;
 * 为它跑一遍完整解析(还要带上 memo 化与块树)成本与耦合都不划算。
 *
 * 只收 http(s) 或站内相对路径的 <img src>:
 *  · 跳过 emoji(站内表情图 `/images/emoji/` 与 class="emoji")—— 它们属于文字,不是配图;
 *  · 跳过 data: 内联图(可能是 base64 小图标,也可能大到没法整屏显示);
 *  · 去重并保持出现顺序(图片墙按楼层顺序左右滑,顺序有意义)。
 */

const IMG_TAG: RegExp = /<img\b[^>]*>/gi;
const SRC_ATTR: RegExp = /\bsrc\s*=\s*"([^"]+)"/i;
const CLASS_ATTR: RegExp = /\bclass\s*=\s*"([^"]*)"/i;

function isEmojiImage(tag: string): boolean {
  const classMatch: RegExpMatchArray | null = tag.match(CLASS_ATTR);
  if (classMatch !== null && classMatch.length > 1 && classMatch[1].indexOf('emoji') >= 0) {
    return true;
  }
  return false;
}

function normalizeUrl(raw: string): string {
  // HTML 实体最常见的两种:&amp; 与 &#39;。不还原会让图片地址 404。
  return raw.trim()
    .replace(/&amp;/g, '&')
    .replace(/&#39;/g, '\'')
    .replace(/&quot;/g, '"');
}

export function collectPostImageUrls(cookedHtml: string): string[] {
  const urls: string[] = [];
  if (cookedHtml.length === 0) {
    return urls;
  }
  const tags: RegExpMatchArray | null = cookedHtml.match(IMG_TAG);
  if (tags === null) {
    return urls;
  }
  for (let index: number = 0; index < tags.length; index++) {
    const tag: string = tags[index];
    if (isEmojiImage(tag)) {
      continue;
    }
    const srcMatch: RegExpMatchArray | null = tag.match(SRC_ATTR);
    if (srcMatch === null || srcMatch.length < 2) {
      continue;
    }
    const url: string = normalizeUrl(srcMatch[1]);
    if (url.length === 0 || url.indexOf('data:') === 0) {
      continue;
    }
    // 站内表情图有两种路径写法(主题组件的 emoji 目录),都按文字处理。
    if (url.indexOf('/images/emoji/') >= 0 || url.indexOf('/emoji/') >= 0) {
      continue;
    }
    if (urls.indexOf(url) < 0) {
      urls.push(url);
    }
  }
  return urls;
}
