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
