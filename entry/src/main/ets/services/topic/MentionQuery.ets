/**
 * @提及补全的纯逻辑(本地 harness 可跑)。
 *
 * 输入框只告诉我们「全文 + 光标位置」,这里负责两件事:
 *  1. 光标前是不是一个正在输入的 @提及(是则给出待补全的词与 @ 的位置);
 *  2. 选中某人后,把 `@待补全词` 整段替换成 `@username `,并把光标放到空格之后。
 *
 * 边界刻意收紧:
 *  · `@` 前必须是开头或空白 —— 否则 `foo@bar.com` 这种邮箱会在输入到一半时弹出一堆用户;
 *  · `@` 与光标之间只能是用户名合法字符(Discourse 用户名:字母数字下划线连字符点),
 *    一旦打了空格/标点就认为这次提及已结束,不再联想;
 *  · 空词(`刚打出 @`)也联想 —— 这正是用户想看到候选的时刻。
 */

export interface MentionContext {
  // @ 在全文里的下标。
  start: number;
  // @ 与光标之间的待补全词(可能为空串)。
  term: string;
}

export interface MentionReplaceResult {
  text: string;
  caret: number;
}

const USERNAME_CHAR: RegExp = /[A-Za-z0-9_.\-]/;
const MAX_TERM_LENGTH: number = 32;

function isUsernameChar(ch: string): boolean {
  return USERNAME_CHAR.test(ch);
}

export function mentionQueryAt(text: string, caret: number): MentionContext | undefined {
  if (caret < 0 || caret > text.length) {
    return undefined;
  }
  let index: number = caret - 1;
  while (index >= 0 && isUsernameChar(text.charAt(index))) {
    index--;
  }
  if (index < 0 || text.charAt(index) !== '@') {
    return undefined;
  }
  // @ 前必须是开头或空白:邮箱/路径里的 @ 不算提及。
  if (index > 0) {
    const before: string = text.charAt(index - 1);
    if (before !== ' ' && before !== '\n' && before !== '\t' && before !== '(' && before !== '，' && before !== ',') {
      return undefined;
    }
  }
  const term: string = text.substring(index + 1, caret);
  if (term.length > MAX_TERM_LENGTH) {
    return undefined;
  }
  return { start: index, term: term };
}

export function replaceMention(text: string, context: MentionContext, username: string, caret: number): MentionReplaceResult {
  const name: string = username.trim();
  if (name.length === 0) {
    return { text: text, caret: caret };
  }
  const head: string = text.substring(0, context.start);
  const tail: string = text.substring(caret);
  // 末尾补一个空格:紧接着继续打字时不会粘在用户名上;已有空格则不重复加。
  const needsSpace: boolean = tail.length === 0 || tail.charAt(0) !== ' ';
  const inserted: string = `@${name}${needsSpace ? ' ' : ''}`;
  return {
    text: `${head}${inserted}${tail}`,
    caret: head.length + inserted.length
  };
}
