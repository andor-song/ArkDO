import { Log } from '../logging/Log';
import webview from '@ohos.web.webview';
import { AppConstants } from '../../common/constants/AppConstants';
import { CookiePresence, containsCookie, cookieValueFromHeader, presenceFromHeader } from './CookieProbe';

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
          Log.i(`${LOG_TAG} cookie save success source=${source} authCookiePresent=${authSnapshot.hasCookie} cookieHeaderLength=${authSnapshot.headerLength}`);
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
      Log.i(`${LOG_TAG} cookie restored name=${cookieName}`);
      return true;
    } catch (error) {
      Log.i(`${LOG_TAG} cookie restore failed name=${cookieName} error=${JSON.stringify(error)}`);
      return false;
    }
  }

  // 唯一的 Cookie 头取用口:异常统一收敛成 undefined(= 探测失败),不再让每个调用点各写一遍 catch。
  private static fetchCookieHeader(url: string): string | undefined {
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
