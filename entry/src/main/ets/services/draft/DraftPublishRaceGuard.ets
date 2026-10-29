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
 * 为什么客户端原先看不见这个 bug:Discourse 的 DraftsController#destroy 是
 *   `return render json: success_json if draft_info.draft_sequence.to_i != params[:draft_sequence].to_i`
 * ——序号不匹配(或压根没有草稿行)时**静默什么都不删,照样回 {"success":"OK"}**。
 * 所以「删除成功」的日志与「草稿确实没了」之间没有等价关系,只能靠次序自证。
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

  /**
   * 删除是否值得发:序号为 0 时 Discourse 必然静默 no-op(见文件头),
   * 与其发一条只会写下「成功」误导日志的请求,不如不发。
   */
  needsDelete(sequence: number): boolean {
    return sequence > 0;
  }
}
