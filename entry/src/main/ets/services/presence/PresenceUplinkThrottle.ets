// 「我在回复」上行的节流器(纯逻辑,无设备依赖)。
// 上游 /presence/update 限流 20 次/10 秒(已核 presence_controller.rb),回复输入过程中
// 进出编辑态的翻转不必每次都发,这里给一个最小间隔兜住。
export class PresenceUplinkThrottle {
  private readonly minIntervalMs: number;
  private lastSentMs: number = -1;

  constructor(minIntervalMs: number) {
    this.minIntervalMs = minIntervalMs;
  }

  shouldSend(nowMs: number): boolean {
    if (this.lastSentMs < 0) {
      return true;
    }
    return nowMs - this.lastSentMs >= this.minIntervalMs;
  }

  markSent(nowMs: number): void {
    this.lastSentMs = nowMs;
  }

  reset(): void {
    this.lastSentMs = -1;
  }
}
