/**
 * 草稿「复活」竞态的判定核心。纯逻辑、无依赖,便于单测。
 *
 * 要解决的问题(真机日志实证 2026-10-28 20:05,topic_2496114):
 *   20:05:34.718 POST /drafts.json start      ← 防抖到点,草稿保存在途
 *   20:05:35.821 POST /posts  success         ← 用户点了发送,回复已发出
 *   20:05:35.825 DELETE /drafts/topic_…start  ← 拿【旧序号】去删
 *   20:05:36.219 POST /drafts.json success    ← 在途那次保存晚于删除才落地!
 * 结果:服务端多出一条「内容 = 刚发出去的那段回复」的草稿,草稿箱里就这么留下了尸体。
 *
 * 为什么客户端原先看不见这个 bug:上游 `Draft#clear` 要求带来的 sequence 与
 * `DraftSequence.current(user, key)` **相等**才动手,不等就 `raise Draft::OutOfSequence`;
 * 而 `DraftsController#destroy` 把这个异常 rescue 掉、注释写着「nothing really we can do here,
 * if try clearing a draft that is not ours, just skip it. rendering an error causes issues in
 * the composer」,末尾照样 `render json: success_json`。所以「删除成功」的日志与「草稿确实没了」
 * 之间没有等价关系 —— 本类只能保证**次序**(先收干在途保存再删),删除是否命中得由服务端现状说话
 * (见 DraftService#deleteDraftByServerState)。
 *
 * 本类只回答两个问题:
 *  1. 现在该不该把文本存成草稿?(发布已经发起 → 不该,不然又写回去)
 *  2. 一次在途保存回包时,期间是否发生过发布?(发生过 → 这条草稿是僵尸,
 *     调用方必须拿**它自己刚拿到的序号**把它删掉,且不记为已持久化)
 */
export class DraftPublishRaceGuard {
  // 发布代号:每次发起「发表/编辑保存」自增。保存发起时拍一张它的快照,
  // 回包时代号变了就说明这次保存跨过了发布 —— 该被清掉而不是被记账。
  private generation: number = 0;
  // 抑制态:发起发布后到用户再次真实编辑之间,不再产生新草稿。
  private suppressed: boolean = false;

  getGeneration(): number {
    return this.generation;
  }

  /** 发起发表/编辑保存。必须在网络请求之前调用,否则在途保存拍不到这一起点。 */
  beginPublish(): void {
    this.generation += 1;
    this.suppressed = true;
  }

  /** 用户真实编辑(非空文本)→ 草稿能力恢复:那是另一段尚未发表的新内容。 */
  noteUserEdit(): void {
    this.suppressed = false;
  }

  isSuppressed(): boolean {
    return this.suppressed;
  }

  /** 保存回包时判断:这次保存是否与发布撞车了。 */
  isLateSave(startGeneration: number): boolean {
    return startGeneration !== this.generation;
  }

  // 这里**不再有**「这条删除值不值得发」的判断。早前一版按 `sequence > 0` 拦,是错的:
  // 上游对一条**从没存过的新 key** 首次保存走 INSERT 分支、回的序号就是 0(此时
  // draft_sequences 还没有行,DraftSequence.current 也是 0),所以序号 0 的草稿是**删得掉**的;
  // 拿 0 当「没有草稿」的信号,恰好把「只自动存过一次就点了发送」这个最常见的情形漏删了。
  // 判据只有一个:服务端自己说有没有行(GET /drafts/{key}.json)。
}
