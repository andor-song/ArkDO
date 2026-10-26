import { Log } from '../logging/Log';
import webview from '@ohos.web.webview';
import { AppConstants } from '../../common/constants/AppConstants';
import { CookiePresence, containsCookie, cookieValueFromHeader, credentialFingerprint, presenceFromHeader } from './CookieProbe';

const LOG_TAG: string = '[ArkDO][WebSession]';

// 认证 cookie 名(Discourse 会话令牌)。集中一处:AuthService 的登出判据与 RootTabPage 的
// 看门狗都要用它,且「探测不到」与「确认没有」在两条链路里都必须是不同的结论。
export const AUTH_COOKIE_NAME: string = '_t';

export interface CookiePresenceSnapshot {
  hasCookie: boolean;
  headerLength: number;
}

export class WebSessionManager {
  private static cookieSaveChain: Promise<void> = Promise.resolve();
  static configureCookieAccess(source: string): void {
    try {
      webview.WebCookieManager.putAcceptCookieEnabled(true);
      webview.WebCookieManager.putAcceptThirdPartyCookieEnabled(true);
      Log.i(`${LOG_TAG} cookie access enabled source=${source} thirdParty=${webview.WebCookieManager.isThirdPartyCookieAllowed()}`);
    } catch (error) {
      Log.i(`${LOG_TAG} cookie access configure failed source=${source} error=${JSON.stringify(error)}`);
    }
  }

  static applyUserAgent(controller: webview.WebviewController, source: string): void {
    try {
      controller.setCustomUserAgent(AppConstants.DEFAULT_USER_AGENT);
      Log.i(`${LOG_TAG} user agent applied source=${source} ua=${AppConstants.DEFAULT_USER_AGENT}`);
    } catch (error) {
      Log.i(`${LOG_TAG} user agent apply failed source=${source} error=${JSON.stringify(error)}`);
    }
  }

  static saveCookies(source: string): Promise<void> {
    // 多个 WebView 的 onPageEnd 可能同时触发保存。串行化保存,避免后一次调用覆盖
    // 前一次尚未落盘的 Cookie 快照;调用方也可以等待该 Promise 再关闭登录页。
    const nextSave: Promise<void> = WebSessionManager.cookieSaveChain.then(() => {
      return webview.WebCookieManager.saveCookieAsync()
        .then(() => {
          const authSnapshot: CookiePresenceSnapshot = WebSessionManager.getCookiePresenceSnapshot('_t');
          // 带指纹而不只是"有没有":服务端每约 10 分钟轮换 `_t`,「换了一枚」与「还是那枚」
          // 在排查掉登录时必须分得开。指纹不可逆,可安全进日志(日志会被导出)。
          const tokenFingerprint: string =
            credentialFingerprint(WebSessionManager.readCookieValue(AppConstants.BASE_URL, AUTH_COOKIE_NAME));
          Log.i(`${LOG_TAG} cookie save success source=${source} authCookiePresent=${authSnapshot.hasCookie} token=${tokenFingerprint} cookieHeaderLength=${authSnapshot.headerLength}`);
        })
        .catch((error: Object) => {
          Log.i(`${LOG_TAG} cookie save failed source=${source} error=${JSON.stringify(error)}`);
        });
    });
    WebSessionManager.cookieSaveChain = nextSave;
    return nextSave;
  }

  static hasCookie(cookieName: string): boolean {
    return WebSessionManager.getCookiePresenceSnapshot(cookieName).hasCookie;
  }

  static getCookiePresenceSnapshot(cookieName: string): CookiePresenceSnapshot {
    return WebSessionManager.getCookiePresenceSnapshotForUrl(AppConstants.BASE_URL, cookieName);
  }

  // 指定站点的 cookie 存在性。cookie 仓按域隔离,副站点(credit.linux.do 等)的会话 cookie
  // 在 BASE_URL 下取不到,必须用它自己的 URL 查——否则会把「已登录副站点」误判成未登录。
  static hasCookieForUrl(url: string, cookieName: string): boolean {
    return WebSessionManager.getCookiePresenceSnapshotForUrl(url, cookieName).hasCookie;
  }

  // 三态探测:探测失败(拿不到 Cookie 头)返回 UNKNOWN,与「确实没有 cookie」严格区分——
  // 只有后者才允许调用方下「未登录」结论。纯解析逻辑在 CookieProbe,可单测。
  static getCookiePresenceForUrl(url: string, cookieName: string): CookiePresence {
    return presenceFromHeader(WebSessionManager.fetchCookieHeader(url), cookieName);
  }

  static getCookiePresenceSnapshotForUrl(url: string, cookieName: string): CookiePresenceSnapshot {
    const cookieHeader: string | undefined = WebSessionManager.fetchCookieHeader(url);
    if (cookieHeader === undefined) {
      return {
        hasCookie: false,
        headerLength: 0
      };
    }
    return {
      hasCookie: containsCookie(cookieHeader, cookieName),
      headerLength: cookieHeader.length
    };
  }

  // 读某个 cookie 的**值**(冷启动写回认证令牌用)。值不落日志。
  static readCookieValue(url: string, cookieName: string): string | undefined {
    return cookieValueFromHeader(WebSessionManager.fetchCookieHeader(url), cookieName);
  }

  // 把 cookie 写回 cookie 仓(含 HttpOnly)。用于冷启动恢复认证令牌:
  // 真机实测 ArkWeb 的磁盘快照在进程重启后**恢复不出** `_t`(落盘时在、重启后 jar 里没有),
  // 会话因此每次冷启动真丢;写回后服务端会据它重新签发会话。
  static restoreCookie(url: string, cookieName: string, value: string): boolean {
    if (value.length === 0) {
      return false;
    }
    try {
      webview.WebCookieManager.configCookieSync(url, `${cookieName}=${value}`, false, true);
      webview.WebCookieManager.saveCookieSync();
      Log.i(`${LOG_TAG} cookie restored name=${cookieName} token=${credentialFingerprint(value)}`);
      return true;
    } catch (error) {
      Log.i(`${LOG_TAG} cookie restore failed name=${cookieName} error=${JSON.stringify(error)}`);
      return false;
    }
  }

  /**
   * 把某个 cookie 从 cookie 仓里删掉。用于「本机还揣着一枚已被服务端拒绝的凭据」时把它清出去。
   *
   * 为什么必须**主动删**，而不是只在恢复时跳过它：请求带不带 cookie 由 Chromium 决定,
   * 不由我们决定。只要那一枚还躺在 jar 里,宿主 webview 发出的**每一个**同源请求都会把它带上,
   * 而上游对「带了无效认证 cookie」的每次请求都会计入**按 IP** 的 cookie_auth 限流
   * (10 次/分钟)。刷满之后,同一 Wi-Fi 下电脑浏览器发出的请求会撞上同一把锁 ——
   * 它那枚**有效**的令牌也会被一并判成 BAD_TOKEN 并被删掉。这就是「手机登录顶掉电脑、
   * 反过来也是」的机制。所以只"不写回"是不够的,还得把已经在 jar 里的那枚清干净。
   *
   * 删除与写入必须**同名、同域、同路径**才删得掉(cookie 的匹配规则)。所以显式带 `path=/`
   * —— 服务端下发 `_t` 用的就是 Rails 默认根路径,与我们 configCookieSync 的推导一致。
   *
   * 返回值只代表「这条指令发出去且没抛异常」,**不代表"jar 里已经没有它了"**(理由见函数体内)。
   * 所以调用方一律无条件尝试删除,不要先读一遍再决定删不删。
   */
  static deleteCookie(url: string, cookieName: string): boolean {
    try {
      webview.WebCookieManager.configCookieSync(url,
        `${cookieName}=; expires=Thu, 01 Jan 1970 00:00:00 GMT; path=/`, false, true);
      webview.WebCookieManager.saveCookieSync();
      // 只作观察,**不作为成功判据**:fetchCookieSync 的第二参是「无痕标志」,SDK 里根本没有
      // includeHttpOnly 这一说(只有 configCookieSync 有),所以 `_t`(HttpOnly)**读不到 ≠ 不存在**。
      // 本仓 1.0.6 的真机记录早就撞见过这点(已登录时 hasCookie('_t') 照样报 absent)。
      // 若把「读不到」当成「删成功了」,日志会一路报 verified=true 而实际什么都没删 ——
      // 一个会让人误以为修复已生效的假信号,比没有信号更坏。
      const readBack: CookiePresence = WebSessionManager.getCookiePresenceForUrl(url, cookieName);
      Log.i(`${LOG_TAG} cookie delete issued name=${cookieName} readBack=${readBack}`);
      return true;
    } catch (error) {
      Log.i(`${LOG_TAG} cookie delete failed name=${cookieName} error=${JSON.stringify(error)}`);
      return false;
    }
  }

  // 唯一的 Cookie 头取用口:异常统一收敛成 undefined(= 探测失败),不再让每个调用点各写一遍 catch。
  // 对外公开(诊断快照要一次拿到「存在性 + 值 + 头长度」三件事,逐个再查一遍 cookie 仓既浪费
  // 又可能读到三个互相矛盾的瞬间)。调用方**不得**把返回值写进日志:里面有 HttpOnly 凭据。
  static fetchCookieHeader(url: string): string | undefined {
    try {
      return webview.WebCookieManager.fetchCookieSync(url, false);
    } catch (error) {
      return undefined;
    }
  }

  static hasCfClearance(): boolean {
    return WebSessionManager.hasCookie('cf_clearance');
  }

  // 取 cf_clearance 的值(不含名字)。挑战弹层用它做"值变化"判定:过期失效的旧 cookie 仍残留在
  // cookie 仓里,靠"存在性"会被误判为已解决而秒关弹层;只有值发生变化才是 CF 真的发了新通行证。
  static getCfClearanceValue(): string {
    try {
      const cookieHeader: string = webview.WebCookieManager.fetchCookieSync(AppConstants.BASE_URL, false);
      const prefix: string = 'cf_clearance=';
      const parts: string[] = cookieHeader.split(';');
      for (let index: number = 0; index < parts.length; index++) {
        const trimmed: string = parts[index].trim();
        if (trimmed.startsWith(prefix)) {
          return trimmed.substring(prefix.length);
        }
      }
      return '';
    } catch (error) {
      return '';
    }
  }

}
