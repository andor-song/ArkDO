/**
 * 主题元数据编辑里的纯逻辑（不碰 UI / 网络，本地 harness 可直跑）。
 */

/**
 * 把用户输入的标签串解析成标签名数组。
 *
 * 两种逗号都认：手机中文输入法默认打出全角「，」，而粘贴来的多半是半角「,」——
 * 只认一种会让用户「明明用逗号隔了却只算一个标签」。同时去空白、丢空项、去重（保序），
 * 因为服务端对重复标签会报错，而用户看不出自己重复了。
 */
export function parseTagInput(raw: string): string[] {
  const parts: string[] = raw.replace(/，/g, ',').split(',');
  const seen: Set<string> = new Set<string>();
  const result: string[] = [];
  for (let index: number = 0; index < parts.length; index++) {
    const name: string = parts[index].trim();
    if (name.length === 0 || seen.has(name)) {
      continue;
    }
    seen.add(name);
    result.push(name);
  }
  return result;
}

/** 两组标签名是否等价（保序比较，用于判断「用户到底改没改」）。 */
export function sameTagNames(a: string[], b: string[]): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let index: number = 0; index < a.length; index++) {
    if (a[index] !== b[index]) {
      return false;
    }
  }
  return true;
}
