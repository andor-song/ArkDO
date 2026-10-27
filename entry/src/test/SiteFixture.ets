/**
 * 单测用的「当前站点」注入器。
 *
 * 为什么要专门有这一个文件：`AppConstants.BASE_URL` / `HOST` 自 0dd98c4「站点地址改为运行时可配」
 * 起不再是编译期常量，而是由 `CurrentSite.init()` 在启动时推进去的**进程级可变全局态**。
 * 测试进程里没有入口 Ability、没人调 init，于是两者都是空串 —— 所有靠它把相对路径补成绝对地址的
 * 断言（resolveUrl、请求 referrer、推送 URL 复原、CF 挑战路径比对）会整批落空。
 *
 * 更阴的一种是**负向断言变成空过**：`isChallengeCompletionResponse` 在站点为空时对所有 URL 都回
 * false，于是「不该判成过盾」那几条用例根本没在测判定逻辑，只是在测"站点没配"。
 *
 * 用法（每个需要站点的 describe 一次）：
 *   beforeAll(() => SiteFixture.pinLinuxDo());
 *   afterAll(() => SiteFixture.restore());
 *
 * 先存后还是硬要求：站点是全局态，泄漏给后面的套件就成了"谁先跑谁通过"。
 * 仓内既有范式见 PushSubscriptionKeys.test.ets:21-30，这里把它收成一处，免得五份注释各写各的。
 */
import { AppConstants, LINUX_DO_HOST } from '../main/ets/common/constants/AppConstants';

// 与用例里字面写的站点保持一致。这里**只用于测试**，不代表产品预置任何站点
// （多站改造刻意把默认值清空，产品语义是"不预置站点"）。
const PINNED_BASE_URL: string = 'https://linux.do';

export class SiteFixture {
  private static savedBaseUrl: string = '';
  private static savedHost: string = '';
  private static pinned: boolean = false;

  /** 钉住站点。幂等：重复调用不会把"已钉的值"当成原值存下来（那会让 restore 变成钉不还原）。 */
  static pinLinuxDo(): void {
    if (SiteFixture.pinned) {
      return;
    }
    SiteFixture.savedBaseUrl = AppConstants.BASE_URL;
    SiteFixture.savedHost = AppConstants.HOST;
    SiteFixture.pinned = true;
    AppConstants.setActiveSite(PINNED_BASE_URL, LINUX_DO_HOST);
  }

  /** 还原本组进入前的站点。没钉过也安全（no-op），免得 afterAll 在异常路径上反手污染全局。 */
  static restore(): void {
    if (!SiteFixture.pinned) {
      return;
    }
    AppConstants.setActiveSite(SiteFixture.savedBaseUrl, SiteFixture.savedHost);
    SiteFixture.pinned = false;
  }
}
