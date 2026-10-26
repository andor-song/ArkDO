// cookie 探测的纯逻辑层：只做「从 Cookie 头里判断某个 cookie 在不在」，不碰任何设备 API。
//
// 为什么要三态而不是 boolean：调用方（AuthService 的「确认登出」判据）需要区分
//   · 明确没有  → 可以据此下结论
//   · 明确有    → 必须保留登录态
//   · 探测本身失败（拿不到 Cookie 头）→ 什么都不能下结论
// 旧实现把「抛异常」也当成「没有 cookie」，等于让一次 API 抖动就宣告用户登出。
// 这里不含 @kit/@ohos 依赖，可被 entry/src/test 直接覆盖。

export enum CookiePresence {
  PRESENT = 'present',
  ABSENT = 'absent',
  UNKNOWN = 'unknown'
}

// 「本机没有这枚凭据」的统一表示。不用空串:空串在日志里几乎读不出来,而它的误读代价很高
// ——「死令牌名单」要求空值**永不匹配**(见 AuthTokenStore.isMarkedDead),把「没有」显示成
// 某个真实哈希就会让此后每次冷启动都误判「备份是死的」,把恢复链路焊死。
export const NO_COOKIE: string = '—';

// Cookie 头形如 `a=1; _t=xyz; b=2`。按 `;` 切分后取 `=` 前的名字做**精确**比对：
// 不能用 indexOf 子串匹配，否则查 `_t` 会命中 `_tx` / `foo_t`。
export function containsCookie(header: string, cookieName: string): boolean {
  if (header.length === 0 || cookieName.length === 0) {
    return false;
  }
  const parts: string[] = header.split(';');
  for (let index: number = 0; index < parts.length; index++) {
    const token: string = parts[index].trim();
    const eqIndex: number = token.indexOf('=');
    const name: string = eqIndex >= 0 ? token.substring(0, eqIndex).trim() : token;
    if (name === cookieName) {
      return true;
    }
  }
  return false;
}

// undefined 表示「根本没拿到 Cookie 头」（探测失败），与空串（拿到了、但确实没有 cookie）语义不同。
export function presenceFromHeader(header: string | undefined, cookieName: string): CookiePresence {
  if (header === undefined) {
    return CookiePresence.UNKNOWN;
  }
  return containsCookie(header, cookieName) ? CookiePresence.PRESENT : CookiePresence.ABSENT;
}

// 取某个 cookie 的**值**（不仅是存在性）。冷启动写回 `_t` 时要用它，
// 且值里可能含 '='（base64 padding），所以只按第一个 '=' 切分、其余原样保留。
// 值一律不进日志。
export function cookieValueFromHeader(header: string | undefined, cookieName: string): string | undefined {
  if (header === undefined || header.length === 0 || cookieName.length === 0) {
    return undefined;
  }
  const parts: string[] = header.split(';');
  for (let index: number = 0; index < parts.length; index++) {
    const token: string = parts[index].trim();
    const eqIndex: number = token.indexOf('=');
    if (eqIndex < 0) {
      continue;
    }
    if (token.substring(0, eqIndex).trim() !== cookieName) {
      continue;
    }
    const value: string = token.substring(eqIndex + 1).trim();
    return value.length > 0 ? value : undefined;
  }
  return undefined;
}

/**
 * 凭据的**不可逆短指纹**（FNV-1a 32 位，定长 8 个十六进制字符）。
 *
 * 为什么日志里需要它，而不是只看「有 / 没有」：`_t` 每约 10 分钟就在服务端轮换一次，
 * 「换了一枚新的」与「还是同一枚」在排查时是两个完全不同的结论，存在性分不开。
 * 指纹能回答三件事：
 *   1) 冷启动写回备份之后，jar 里生效的是备份那枚还是 Chromium 自己恢复出来的那枚；
 *   2) 服务端判 BAD_TOKEN 时，被拒的是哪一枚（与上一行比对即知是不是在重放死令牌）；
 *   3) 手机与电脑是否共用了同一枚令牌（两端指纹相同 = 共享；不同 = 各有独立会话）。
 *
 * 指纹不是凭据本身：不可逆、不记原值，因此可以进日志（日志能从设置页导出给他人看）。
 * 空值一律返回 NO_COOKIE，避免把「没有 cookie」显示成某个真实哈希。
 *
 * 纯 ArkTS、不用 BigInt：FNV-1a 的 `h * 16777619` 若直接相乘最大约 2^32 × 1.68e7 ≈ 7.2e16，
 * 超过 double 的精确整数上限 2^53，**会丢精度**。按标准做法把乘数拆开
 * （16777619 = 2^24 + 2^8 + 2^7 + 2^4 + 2^1 + 2^0）改成移位相加：每一项经 `<<` + `>>>0`
 * 后都落在 2^32 内，六项之和 < 6 × 2^32 ≈ 2.6e10 仍远小于 2^53，因此精确，末尾 `>>>0` 取模 2^32。
 */
export function credentialFingerprint(value: string | undefined): string {
  if (value === undefined || value.length === 0) {
    return NO_COOKIE;
  }
  let hash: number = 0x811c9dc5;
  for (let index: number = 0; index < value.length; index++) {
    hash = (hash ^ (value.charCodeAt(index) & 0xff)) >>> 0;
    hash = (hash + ((hash << 1) >>> 0) + ((hash << 4) >>> 0) + ((hash << 7) >>> 0)
      + ((hash << 8) >>> 0) + ((hash << 24) >>> 0)) >>> 0;
  }
  const hex: string = (hash >>> 0).toString(16);
  return hex.length >= 8 ? hex.substring(0, 8) : '0'.repeat(8 - hex.length) + hex;
}
