import { common } from '@kit.AbilityKit';
import { AppConstants } from '../../common/constants/AppConstants';
import { AppSettingsStore } from '../../common/prefs/AppSettingsStore';
import { Log } from '../logging/Log';
import { CurrentSite } from '../site/CurrentSite';
import { CookiePresence, NO_COOKIE, credentialFingerprint, presenceFromHeader } from '../web/CookieProbe';
import { WebSessionManager } from '../web/WebSessionManager';
import { AuthSecretStore } from './AuthSecretStore';

const LOG_TAG: string = '[ArkDO][AuthToken]';

/**
 * 认证凭据（`_t` / `_forum_session`）的**本机账本**：备份、判死标记、诊断快照。
 *
 * 为什么要单独立一层（原先这些散在 RootTabPage 的私有方法里）：会话链路要用它做决策，
 * 诊断页也要能用它回答「现在本机拿着哪一枚、备份是哪一枚、这枚被服务端拒过没有」。
 * 散在页面里时，诊断页只能自己再拼一遍键名与别名 —— 拼错不会报错，只会显示「没有备份」，
 * 而这条链路的全部价值就在于读得准。
 *
 * ## 「判死标记」为什么必要
 * 上游对失效令牌会回响应头 `Discourse-Logged-Out: 1`，并顺带 Set-Cookie 删掉浏览器侧那一份。
 * 但**我们自己的备份删不掉**（它躺在系统密钥库里）。没有标记时，冷启动会把同一枚作废令牌
 * 重新灌回 cookie 仓：每重放一次，既让自己继续 404，又计入上游**按 IP** 计的 cookie_auth
 * 限流（10 次/分钟，见 default_current_user_provider.rb 的 `cookie_auth_#{request.ip}`）。
 * 同一 Wi-Fi 下电脑浏览器发的请求会撞上同一把锁，于是它的**有效**令牌也会被一并判成 BAD_TOKEN
 * 并删 cookie —— 用户看到的正是「手机登录顶掉电脑，反过来也是」。
 *
 * ## 这里为什么只记指纹、不记值
 * 凭据是可以直接冒用身份的东西，绝不进 preferences 之外的任何明文存储，更不进日志；
 * 而日志与诊断快照又必须能区分「同一枚」与「换了一枚」（`_t` 约每 10 分钟轮换一次）。
 * 8 位十六进制的不可逆短指纹同时满足两边：可比对、可导出、泄露出去也用不了。
 */

// 需要备份的认证 cookie。两个都要备：`_t` 是 remember-me 令牌（服务端据此重建会话），
// `_forum_session` 是承载会话的 session cookie；只补其中一个，真机实测仍可能判匿名。
export const PERSISTED_AUTH_COOKIES: string[] = ['_t', '_forum_session'];

const SECRET_ALIAS_PREFIX: string = 'arkdo_auth_';
// 「这枚凭据被服务端判过死」的标记（值 = 那枚凭据的指纹）。
const DEAD_TOKEN_KEY_PREFIX: string = 'dead_token_';
// 旧版（1.0.7 之前）把凭据明文存在 preferences 里，迁移时读一次随即删除。
const LEGACY_COOKIE_KEY_PREFIX: string = 'auth_cookie_';
// 最近一次被拒的时间戳与指纹，只记 `_t`：诊断页一行说明即可，两个 cookie 混记反而看不清。
const LAST_REJECT_TIME_KEY: string = 'auth_token_last_reject_at';
const LAST_REJECT_FINGERPRINT_KEY: string = 'auth_token_last_reject_fp';

/** 本机凭据现状的完整快照（诊断用；一次读全，避免多次读 cookie 仓读到互相矛盾的瞬间）。 */
export interface AuthTokenSnapshot {
  // jar（ArkWeb cookie 仓）里的实际状态 —— 下一次请求会带出去的那一枚。
  jarPresence: CookiePresence;
  jarFingerprint: string;
  // 密钥库备份里的状态 —— 下一次冷启动会被灌回来的那一枚。
  backupPresent: boolean;
  backupFingerprint: string;
  // 两者是否已被判死标记命中。
  jarMarkedDead: boolean;
  backupMarkedDead: boolean;
  // 最近一次被服务端拒的时间（0 = 从未）与当时的指纹。
  lastRejectedAt: number;
  lastRejectedFingerprint: string;
  headerLength: number;
}

export class AuthTokenStore {
  static secretAlias(cookieName: string): string {
    return `${SECRET_ALIAS_PREFIX}${CurrentSite.host}_${cookieName}`;
  }

  static deadTokenKey(cookieName: string): string {
    return `${DEAD_TOKEN_KEY_PREFIX}${CurrentSite.host}_${cookieName}`;
  }

  static legacyCookieKey(cookieName: string): string {
    return `${LEGACY_COOKIE_KEY_PREFIX}${CurrentSite.host}_${cookieName}`;
  }

  private static lastRejectTimeKey(): string {
    return `${LAST_REJECT_TIME_KEY}_${CurrentSite.host}`;
  }

  private static lastRejectFingerprintKey(): string {
    return `${LAST_REJECT_FINGERPRINT_KEY}_${CurrentSite.host}`;
  }

  // 判死名单的容量上限。被拒一次通常只涉及一两枚（jar 那枚 + 备份那枚），留几个位置是为
  // 了容忍"轮换途中被拒"这种一次涉及相邻两枚的情形；上限存在的意义是它**永不受限增长**——
  // 一个会随时间变长的名单终会淹掉真正的命中，而名单只需覆盖「还可能被恢复回来的那几枚」。
  static readonly MAX_DEAD_TOKENS: number = 6;

  /**
   * 名单序列化：逗号分隔的指纹串，去重、新的排在前、超过上限从尾部截断。
   *
   * 纯函数（不碰存储），便于单测；`join` 的输入已由调用方保证是合法指纹。
   */
  static mergeDeadList(existing: string, fingerprint: string): string {
    // 空值占位符永不入名单:名单里一旦出现它,"jar 里没 cookie"这个正常游客态就会被
    // deadListContains 判成命中,此后每次冷启动都以为备份是死的 —— 恢复链路被自己焊死。
    if (fingerprint === NO_COOKIE) {
      return existing;
    }
    const items: string[] = [];
    if (existing.length > 0) {
      const previous: string[] = existing.split(',');
      for (let index: number = 0; index < previous.length; index++) {
        const item: string = previous[index].trim();
        if (item.length > 0 && item !== fingerprint && !items.includes(item)) {
          items.push(item);
        }
      }
    }
    items.unshift(fingerprint);
    return items.slice(0, AuthTokenStore.MAX_DEAD_TOKENS).join(',');
  }

  /** 名单里是否含这一枚（空值不参与匹配，见 isMarkedDead）。 */
  static deadListContains(existing: string, fingerprint: string): boolean {
    if (existing.length === 0 || fingerprint === NO_COOKIE) {
      return false;
    }
    return existing.split(',').includes(fingerprint);
  }

  /**
   * 记下「这一枚被服务端判过死」。只在服务端**亲口**拒绝后调用。
   *
   * 值为空（服务端删 cookie 删得比这次读取更快）时**不记**：没有指纹可钉，而乱记一个
   * `'—'` 会把今后所有「jar 里没有 cookie」的正常游客态误判成死令牌，反而把恢复链路关掉。
   *
   * 用名单而不是单值：同一枚 cookie 在一次拒签里可能同时牵出 jar 那枚与备份那枚（服务端
   * 刚轮换过时两者不同）。单值会被后来者覆盖，被覆盖掉的那一枚就又"清白"了 —— 而它正是
   * 可能被磁盘快照带回来的那一枚。
   */
  private static markRejectedValue(context: common.Context, cookieName: string,
    value: string | undefined, rejectedByServer: boolean): void {
    const fingerprint: string = credentialFingerprint(value);
    if (fingerprint === NO_COOKIE) {
      return;
    }
    const existing: string = AppSettingsStore.getString(context, AuthTokenStore.deadTokenKey(cookieName)) ?? '';
    AppSettingsStore.putString(context, AuthTokenStore.deadTokenKey(cookieName),
      AuthTokenStore.mergeDeadList(existing, fingerprint));
    // 两种"该被隔离"的来源分开记:被服务端拒签 = 异常,值得进拒签时间线供排查;
    // 用户主动退出 = 正常动作,写进时间线会让下次看的人误以为发生过拒签。
    Log.i(`${LOG_TAG} token quarantined name=${cookieName} fingerprint=${fingerprint} reason=${rejectedByServer ? 'server-rejected' : 'local-logout'}`);
    if (rejectedByServer && cookieName === '_t') {
      AppSettingsStore.putNumber(context, AuthTokenStore.lastRejectTimeKey(), Date.now());
      AppSettingsStore.putString(context, AuthTokenStore.lastRejectFingerprintKey(), fingerprint);
    }
  }

  /**
   * 服务端宣告「本次携带的认证令牌已作废」时的处置。做三件事：
   *
   *   1) **钉指纹**（jar 那枚 + 备份那枚都钉）。两者通常相同；不同说明服务端已轮换过，
   *      此时备份那枚要么是上一枚（同样已死），要么正是本次被拒的那枚，都钉住最稳妥。
   *      名单一钉上，restoreIntoCookieJar 就再也不会把它灌回 cookie 仓 —— 这是"永久隔离"那半。
   *   2) **清 cookie 仓**（**无条件**，理由见函数体第一条注释）。这一步不能省：带不带 cookie
   *      出去由 Chromium 决定，不由我们决定。只要那一枚还躺在 jar 里，宿主 webview 发出的
   *      **每一个**同源请求都会把它带上，每个都计入上游**按 IP** 的 cookie_auth 限流；刷满之后
   *      同一 Wi-Fi 下电脑浏览器那枚**有效**令牌也会被一并判死并删 cookie —— 那才是「互踢」的
   *      机制本身。只做 1) 等于"下次开机不用它"，而**此刻**这些请求还在继续投毒。
   *   3) 顺手删掉**旧版明文键**（1.0.7 之前写过；留着它就是一条活的复活路径）。
   *
   * **刻意不删密钥库里的备份。** 直觉上"当场销毁"更彻底，其实不安全:本方法的删除发生在
   * `await loadBackup(...)` 之后,而从"读完"到"删掉"之间用户可能刚好重新登录并备份一枚**新的
   * 有效凭据**(同一个别名、同一个 key),而删除按**别名**生效 —— 新备份会被连坐抹掉。
   * 名单没这个问题:它钉的是"值"的属性,新备份指纹不同、天然不受影响。所以真正的删除留给唯一
   * 能精确认出"就是这一枚"的那一步(restoreIntoCookieJar → removeBackupIfSame),判定与清理同一条件。
   *
   * 顺带一句:备份会不会本来就是**比 jar 更新**的有效令牌?不会 —— 备份是从 jar 抄出来的
   * (backupCurrentCookies 只读 jar),只可能等于或落后于它,所以"这枚是死的"对备份同样成立。
   *
   * 只在 404（服务端查过且查不到）时调用。403 是**本机撞限流**、令牌可能仍然有效，
   * 走这里会把「等一分钟就好」误升级成「强制重登」—— 判据见 SessionVerdict.isTokenDeclaredDead。
   *
   * ## 万一指纹撞车（把有效令牌钉进了名单）
   * 32 位指纹对上百字符的令牌，碰撞概率极低；真撞上的后果也**不是永久焊死**：
   * 这一次不恢复 → 服务端 404 → 界面落到游客态 → 用户重新登录 → 会话检查拿到 logged-in
   * 时 clearDeadMarks 把整份名单清掉。失败模式是"多登录一次"，不是"再也登不上"。
   */
  static async rejectAll(context: common.Context): Promise<void> {
    await AuthTokenStore.quarantineAll(context, true);
  }

  /** rejectedByServer 只影响"要不要记进拒签时间线",隔离动作本身两者相同。 */
  private static async quarantineAll(context: common.Context, rejectedByServer: boolean): Promise<void> {
    for (let index: number = 0; index < PERSISTED_AUTH_COOKIES.length; index++) {
      const cookieName: string = PERSISTED_AUTH_COOKIES[index];
      const jarValue: string | undefined = WebSessionManager.readCookieValue(AppConstants.BASE_URL, cookieName);
      AuthTokenStore.markRejectedValue(context, cookieName, jarValue, true);
      const backupValue: string | undefined = await AuthTokenStore.loadBackup(context, cookieName);
      if (backupValue !== undefined) {
        AuthTokenStore.markRejectedValue(context, cookieName, backupValue, true);
      }
      // **无条件**删 cookie 仓里那一枚，不先看 jar 里有没有：`_t` 是 HttpOnly，而
      // fetchCookieSync 没有 includeHttpOnly 参数（见 WebSessionManager.deleteCookie），
      // 所以「读不到」是常态而不是「不存在」。拿读不到当闸门，恰好会把最关键的那一枚放行。
      WebSessionManager.deleteCookie(AppConstants.BASE_URL, cookieName);
      // 旧版明文键：只有 1.0.7 之前的版本写过、我们从不写它，删它没有竞态；留着的话
      // loadBackup 在密钥库读不到时会回落到它、把这枚死令牌重新迁移进密钥库。
      AppSettingsStore.remove(context, AuthTokenStore.legacyCookieKey(cookieName));
    }
    Log.i(`${LOG_TAG} credentials quarantined (fingerprints pinned, cookie jar cleared)`);
  }

  /**
   * 备份/恢复前先问：这一枚是不是已经被服务端拒过？是则一律不再使用。
   *
   * **空值永不匹配**：无值 → 指纹是 NO_COOKIE → 直接 false。少了这道闸，"名单里存过某个
   * 占位值"就会让此后每一次冷启动都判"备份是死的"，把恢复链路彻底焊死。
   */
  static isMarkedDead(context: common.Context, cookieName: string, value: string | undefined): boolean {
    const list: string =
      AppSettingsStore.getString(context, AuthTokenStore.deadTokenKey(cookieName)) ?? '';
    return AuthTokenStore.deadListContains(list, credentialFingerprint(value));
  }

  /** 会话重新建立 = 手里是一枚全新的凭据，旧标记不该继续拦它。 */
  static clearDeadMarks(context: common.Context): void {
    for (let index: number = 0; index < PERSISTED_AUTH_COOKIES.length; index++) {
      const key: string = AuthTokenStore.deadTokenKey(PERSISTED_AUTH_COOKIES[index]);
      // 先读再删:这个方法挂在**每次**会话检查成功上(前台、下拉刷新、看门狗都会走),
      // 而判死标记是极少写的东西 —— 无脑删等于每次成功检查都为两个不存在的键各做一次
      // 磁盘 flush。读是内存操作，只在确实存着时才付那次写的代价。
      const stored: string | undefined = AppSettingsStore.getString(context, key);
      if (stored !== undefined && stored.length > 0) {
        AppSettingsStore.remove(context, key);
      }
    }
  }

  /**
   * 用户主动退出登录时的本机处置。
   *
   * 与 rejectAll 走**同一套隔离动作**（钉指纹 + 清 jar；备份交给恢复那一步按值删）：
   * 服务端在那次 `DELETE /session/{username}` 里已经销毁了这枚令牌，它与"被服务端判死"的
   * 令牌在本机该受到的待遇完全一样 —— 绝不能再被写回 cookie 仓。
   *
   * 补的正是原先那个洞：按别名销毁备份是异步且不等待的，进程若在登出后立刻被回收，密钥库里
   * 那枚已注销的凭据就还在，下次冷启动会原样把它灌回去、把人"自动登录"回一个已经不存在的会话。
   * 现在同一枚的指纹先被钉进名单，restoreIntoCookieJar 见到它就跳过 —— 删没删成都拦得住。
   *
   * 之后用户重新登录成功时，会话链路会调 clearDeadMarks 把名单清掉，所以不会挡住新令牌。
   * 拒签时间线（诊断用）在这里**不写**：用户主动退出不是"被服务端拒签"，写进去会让下次排查把
   * 两条性质相反的事看成一件；顺手把**历史**记录抹掉，同理。
   */
  static async revokeLocalSession(context: common.Context): Promise<void> {
    await AuthTokenStore.quarantineAll(context, false);
    AppSettingsStore.remove(context, AuthTokenStore.lastRejectTimeKey());
    AppSettingsStore.remove(context, AuthTokenStore.lastRejectFingerprintKey());
  }

  /**
   * 备份当前 jar 里的凭据（会话确认成功后调用）。
   * 已被判死的同一枚**绝不备份** —— 否则下次冷启动又把它灌回来重放。
   */
  static backupCurrentCookies(context: common.Context): void {
    for (let index: number = 0; index < PERSISTED_AUTH_COOKIES.length; index++) {
      const cookieName: string = PERSISTED_AUTH_COOKIES[index];
      const value: string | undefined = WebSessionManager.readCookieValue(AppConstants.BASE_URL, cookieName);
      if (value === undefined) {
        continue;
      }
      if (AuthTokenStore.isMarkedDead(context, cookieName, value)) {
        Log.i(`${LOG_TAG} skip backing up a rejected cookie name=${cookieName}`);
        continue;
      }
      AuthSecretStore.save(AuthTokenStore.secretAlias(cookieName), value)
        .catch(() => { Log.i(`${LOG_TAG} backup save failed name=${cookieName}`); });
    }
  }

  /** 读备份；备份缺失时顺带把旧版明文迁进密钥库并删掉明文副本（一次性）。 */
  static async loadBackup(context: common.Context, cookieName: string): Promise<string | undefined> {
    const stored: string | undefined = await AuthSecretStore.load(AuthTokenStore.secretAlias(cookieName));
    if (stored !== undefined) {
      return stored;
    }
    const legacy: string | undefined = AppSettingsStore.getString(context, AuthTokenStore.legacyCookieKey(cookieName));
    if (legacy === undefined) {
      return undefined;
    }
    await AuthSecretStore.save(AuthTokenStore.secretAlias(cookieName), legacy);
    AppSettingsStore.remove(context, AuthTokenStore.legacyCookieKey(cookieName));
    Log.i(`${LOG_TAG} migrated legacy plaintext backup name=${cookieName}`);
    return legacy;
  }

  private static async removeBackup(cookieName: string): Promise<void> {
    await AuthSecretStore.remove(AuthTokenStore.secretAlias(cookieName));
  }

  /**
   * 仅当「当前存的确实还是这个值」时才删 —— **值作用域**的删除。
   *
   * 必要性:本服务所有删除都发生在 await 之后，而写备份（backupCurrentCookies）随时可能发生。
   * 按别名删会把期间刚写入的**新有效凭据**一起抹掉。宁可漏删（下次冷启动再删，反正名单已经
   * 让它不被使用），也绝不误删。
   */
  static async removeBackupIfSame(cookieName: string, value: string): Promise<void> {
    const current: string | undefined = await AuthSecretStore.load(AuthTokenStore.secretAlias(cookieName));
    if (current !== value) {
      Log.i(`${LOG_TAG} backup changed before delete, kept name=${cookieName}`);
      return;
    }
    await AuthTokenStore.removeBackup(cookieName);
  }


  /**
   * 冷启动写回（必须在首次会话检查**之前**）。
   *
   * **总是覆盖**，不是「缺了才补」：真机实测 ArkWeb 能把登录前的匿名 `_forum_session` 从磁盘
   * 恢复出来，而 Discourse 取值时先认 session、再认 `_t` —— 旧的匿名 session 会把刚补上的
   * 有效 `_t` 挡住，服务端照样回 404（2026-10-14 14:22 那次）。
   */
  static async restoreIntoCookieJar(context: common.Context): Promise<void> {
    for (let index: number = 0; index < PERSISTED_AUTH_COOKIES.length; index++) {
      const cookieName: string = PERSISTED_AUTH_COOKIES[index];
      const value: string | undefined = await AuthTokenStore.loadBackup(context, cookieName);
      if (value === undefined) {
        continue;
      }
      if (AuthTokenStore.isMarkedDead(context, cookieName, value)) {
        Log.i(`${LOG_TAG} backup is a known-dead token, not restoring name=${cookieName}`);
        // 删的是**刚读出来这一份值**，不是"这个别名下的当前值":异步删除之间若有新备份写入
        // (用户刚好登录成功并备份了新凭据)，按别名删会把有效凭据连坐删掉。值对上了才动手。
        await AuthTokenStore.removeBackupIfSame(cookieName, value);
        continue;
      }
      Log.i(`${LOG_TAG} restoring backup name=${cookieName} token=${credentialFingerprint(value)}`);
      WebSessionManager.restoreCookie(AppConstants.BASE_URL, cookieName, value);
    }
  }

  /** 诊断快照：本机凭据的「jar / 备份 / 判死 / 被拒时间线」一次读全。 */
  static async snapshot(context: common.Context): Promise<AuthTokenSnapshot> {
    const header: string | undefined = WebSessionManager.fetchCookieHeader(AppConstants.BASE_URL);
    const jarValue: string | undefined = WebSessionManager.readCookieValue(AppConstants.BASE_URL, '_t');
    const backupValue: string | undefined = await AuthTokenStore.loadBackup(context, '_t');
    const lastRejectFp: string | undefined =
      AppSettingsStore.getString(context, AuthTokenStore.lastRejectFingerprintKey());
    return {
      jarPresence: presenceFromHeader(header, '_t'),
      jarFingerprint: credentialFingerprint(jarValue),
      backupPresent: backupValue !== undefined && backupValue.length > 0,
      backupFingerprint: credentialFingerprint(backupValue),
      jarMarkedDead: AuthTokenStore.isMarkedDead(context, '_t', jarValue),
      backupMarkedDead: AuthTokenStore.isMarkedDead(context, '_t', backupValue),
      lastRejectedAt: AppSettingsStore.getNumber(context, AuthTokenStore.lastRejectTimeKey(), 0),
      lastRejectedFingerprint: lastRejectFp !== undefined && lastRejectFp.length > 0 ? lastRejectFp : NO_COOKIE,
      headerLength: header !== undefined ? header.length : 0
    };
  }
}
