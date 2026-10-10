import { AppConstants } from '../../common/constants/AppConstants';

export const ARKDO_PUSH_URL_KEY: string = 'arkdo_url';
export const ARKDO_PUSH_TITLE_KEY: string = 'arkdo_title';
// 通知所属站点。中继按订阅记录里的站点写入,客户端据此决定要不要先切论坛。
export const ARKDO_PUSH_SITE_HOST_KEY: string = 'arkdo_site_host';
export const ARKDO_PUSH_DATA_KEY: string = 'arkdo_push_data';

export interface PushNotificationRoute {
  id: number;
  url: string;
  title?: string;
  source: string;
  createdAt: number;
  /**
   * 这条通知属于哪个论坛(host)。空串 = 中继没给(老服务端),按当前论坛处理。
   * 与当前论坛不一致时,消费方须先切过去再跳,否则会拿另一个论坛的地址去开这个 topicId。
   */
  siteHost: string;
}

interface DiscoursePushPayload {
  title?: string;
  url?: string;
  base_url?: string;
}

interface PushClickParameters {
  arkdo_url?: string;
  arkdo_title?: string;
  arkdo_push_data?: string | Object;
  url?: string;
  title?: string;
  data?: string | Object;
  pushData?: string | Object;
  notificationData?: string | Object;
  arkdo_site_host?: string;
}

interface PushClickData {
  arkdo_url?: string;
  arkdo_title?: string;
  url?: string;
  title?: string;
  arkdo_site_host?: string;
}

let routeSequence: number = 0;

export function buildPushClickData(url: string, title?: string): string {
  const data: PushClickData = {
    arkdo_url: url
  };
  if (title && title.length > 0) {
    data.arkdo_title = title;
  }
  return JSON.stringify(data);
}

export function extractRouteFromDiscoursePayload(payload: Object | undefined): PushNotificationRoute | undefined {
  if (!payload) {
    return undefined;
  }
  const data: DiscoursePushPayload = payload as DiscoursePushPayload;
  if (typeof data.url !== 'string' || data.url.length === 0) {
    return undefined;
  }
  return buildRoute(data.url, typeof data.title === 'string' ? data.title : undefined, data.base_url, 'discourse');
}

export function parsePushNotificationRouteFromParameters(parameters: Object | undefined): PushNotificationRoute | undefined {
  if (!parameters) {
    return undefined;
  }
  const source: PushClickParameters = parameters as PushClickParameters;
  const direct: PushNotificationRoute | undefined = buildRoute(
    firstNonEmpty(source.arkdo_url, source.url),
    firstNonEmpty(source.arkdo_title, source.title),
    undefined,
    'want',
    source.arkdo_site_host
  );
  if (direct) {
    return direct;
  }

  return parseClickData(source.arkdo_push_data) ??
    parseClickData(source.data) ??
    parseClickData(source.pushData) ??
    parseClickData(source.notificationData);
}

/**
 * 把推送里的地址解析成可跳转的绝对 URL。
 *
 * declaredHost 是中继声明的「这条通知属于哪个论坛」。原先这里只认与当前论坛同源的地址,
 * 跨站一律返回空串 —— 那在单站时代是对的安全兜底,多站之后却导致「切到 B 站时收到 A 站的
 * 通知,点了毫无反应」。现在放宽为:**目标 host 与中继声明的站点一致即接受**,由消费方
 * 负责先切到那个论坛再跳。校验并没有放弃 —— 仍然拒绝声明之外的任何第三方地址。
 */
export function resolveDiscoursePushUrl(rawUrl: string | undefined, baseUrl?: string, declaredHost?: string): string {
  const raw: string = rawUrl ? rawUrl.trim() : '';
  if (raw.length === 0) {
    return '';
  }
  const declared: string = declaredHost ? declaredHost.trim().toLowerCase() : '';
  if (raw.startsWith('/')) {
    let base: string = AppConstants.BASE_URL;
    if (sameHostBase(baseUrl) || (declared.length > 0 && hostOf(baseUrl ?? '') === declared)) {
      base = (baseUrl as string).replace(/\/+$/, '');
    } else if (declared.length > 0) {
      base = `https://${declared}`;
    }
    return `${base}${raw}`;
  }
  if (/^https?:\/\//i.test(raw)) {
    if (sameHostBase(raw)) {
      return raw;
    }
    // 跨站:只接受与中继声明一致的站点,其余(声明缺失或对不上)照旧拒绝。
    return declared.length > 0 && hostOf(raw) === declared ? raw : '';
  }
  return '';
}

export function describePushNotificationRoute(route: PushNotificationRoute): string {
  return route.url.replace(/^https?:\/\/[^\/?#]+/i, '').replace(/[?#].*$/, '');
}

function parseClickData(value: string | Object | undefined): PushNotificationRoute | undefined {
  if (!value) {
    return undefined;
  }

  if (typeof value === 'string') {
    if (value.length === 0) {
      return undefined;
    }
    try {
      const parsed: PushClickData = JSON.parse(value) as PushClickData;
      return routeFromClickData(parsed);
    } catch (err) {
      return buildRoute(value, undefined, undefined, 'want-data');
    }
  }

  return routeFromClickData(value as PushClickData);
}

function routeFromClickData(data: PushClickData): PushNotificationRoute | undefined {
  return buildRoute(
    firstNonEmpty(data.arkdo_url, data.url),
    firstNonEmpty(data.arkdo_title, data.title),
    undefined,
    'want-data'
  );
}

function buildRoute(rawUrl: string | undefined, title: string | undefined, baseUrl: string | undefined,
  source: string, siteHost?: string): PushNotificationRoute | undefined {
  const declaredHost: string = siteHost ? siteHost.trim().toLowerCase() : '';
  const url: string = resolveDiscoursePushUrl(rawUrl, baseUrl, declaredHost);
  if (url.length === 0) {
    return undefined;
  }
  routeSequence++;
  const route: PushNotificationRoute = {
    id: routeSequence,
    url: url,
    source: source,
    createdAt: Date.now(),
    // 声明缺失时用 URL 自身的 host 兜底:老服务端不给这个字段,而 URL 里本来就带着站点。
    siteHost: declaredHost.length > 0 ? declaredHost : hostOf(url)
  };
  const cleanTitle: string = title ? title.trim() : '';
  if (cleanTitle.length > 0) {
    route.title = cleanTitle;
  }
  return route;
}

function firstNonEmpty(first?: string, second?: string): string | undefined {
  const a: string = first ? first.trim() : '';
  if (a.length > 0) {
    return a;
  }
  const b: string = second ? second.trim() : '';
  return b.length > 0 ? b : undefined;
}

function sameHostBase(url: string | undefined): boolean {
  if (!url || url.length === 0) {
    return false;
  }
  return hostOf(url) === hostOf(AppConstants.BASE_URL);
}

function hostOf(url: string): string {
  const match: RegExpMatchArray | null = url.match(/^https?:\/\/([^\/?#]+)/i);
  return match ? match[1].toLowerCase() : '';
}
// ---------------------------------------------------------------------------
// 深链(URL scheme arkdo://)
//
// App 对外暴露的自定义 scheme。可从浏览器 / 其它 App 唤起,支持四类目标:
//  1. 站内帖子:  arkdo://t/<topicId>[/<postNumber>]            (同站,按当前论坛取)
//  2. 站内用户:  arkdo://u/<username>
//  3. 指定论坛:  arkdo://<host>/…                               (host 是论坛域名,如 arkdo://linux.do/t/123 → /t/123)
//  4. 通用站点:  arkdo://browse?url=<urlencoded 绝对链接>        (任意已订阅论坛的链接)
//
// 解析只出一件事:把它规整成一条 PushNotificationRoute 交回既有的推送导航通路——
// 冷启动 pending、跨站先切论坛、LinkRouter 原生/Web 分流,全部免费复用,不另起炉灶。
// 这也是为什么 source 用 'deeplink' 而结构完全一致:消费方不关心它来自推送还是深链。
// ---------------------------------------------------------------------------
const ARKDO_SCHEME: string = 'arkdo://';

export function parseArkDoUriToRoute(uri: string | undefined, title?: string): PushNotificationRoute | undefined {
  const raw: string = uri ? uri.trim() : '';
  if (raw.length === 0 || !raw.toLowerCase().startsWith(ARKDO_SCHEME)) {
    return undefined;
  }
  const rest: string = raw.substring(ARKDO_SCHEME.length);
  if (rest.length === 0) {
    return undefined;
  }

  // 4. 通用站点:参数里带完整绝对链接。
  if (rest.toLowerCase().startsWith('browse?')) {
    const params: string = rest.substring('browse?'.length);
    const urlValue: string = queryParamOf(params, 'url');
    if (urlValue.length === 0) {
      return undefined;
    }
    return buildRoute(urlValue, title, undefined, 'deeplink');
  }

  // 1/2/3. 站内路径或指定论坛。拆 host + path:
  //    arkdo://t/123      → host='t'        path='/123'
  //    arkdo://linux.do/u/x → host='linux.do' path='/u/x'
  const slash: number = rest.indexOf('/');
  let host: string = '';
  let path: string = '';
  if (slash < 0) {
    host = rest;
  } else {
    host = rest.substring(0, slash);
    path = rest.substring(slash);
  }
  host = host.trim();
  path = path.trim();
  if (path.length === 0) {
    path = '/';
  }

  // host 看起来是论坛域名(带点/端口) → 构造绝对链接,declaredHost 用该 host。
  if (isHostLike(host)) {
    const probe: string = `https://${host}${path}`;
    return buildRoute(probe, title, undefined, 'deeplink', host);
  }

  // 纯站内路径:按当前论坛拼。相对路径让 resolveDiscoursePushUrl 用当前 BASE_URL 落。
  // 此时不带 declaredHost(siteHost 由消费方按 URL 派生,即当前论坛)。
  if (host.length > 0) {
    path = `/${host}${path}`;
  }
  return buildRoute(path, title, undefined, 'deeplink');
}

// 是否像论坛域名:带点号(linux.do)或带端口(host:port)。宿主段语义关键字(如 t/u)不含点,不会误判。
function isHostLike(host: string): boolean {
  return /[.:]/.test(host);
}

// 从 query 里取首个指定参数值(urlencoded 已由构建方编码,这里按需做一次安全解码)。
function queryParamOf(query: string, key: string): string {
  const pairs: string[] = query.split('&');
  for (let index: number = 0; index < pairs.length; index++) {
    const pair: string = pairs[index];
    const eq: number = pair.indexOf('=');
    if (eq < 0) {
      continue;
    }
    const k: string = pair.substring(0, eq);
    if (k !== key) {
      continue;
    }
    let v: string = pair.substring(eq + 1);
    try {
      v = decodeURIComponent(v);
    } catch (error) {
      // 不解码失败就原样用。
    }
    return v.trim();
  }
  return '';
}
