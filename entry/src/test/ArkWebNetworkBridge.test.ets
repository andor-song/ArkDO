import { afterAll, describe, it, expect } from '@ohos/hypium';
import { ArkWebJsonExecutor, ArkWebNetworkBridge } from '../main/ets/services/network/ArkWebNetworkBridge';
import { ChallengeState, NetworkErrorCode, NetworkFailureKind, NetworkResult } from '../main/ets/services/network/NetworkTypes';
import { ChallengeEventBus, ChallengeRequiredEvent } from '../main/ets/services/challenge/ChallengeEventBus';
import { SiteFixture } from './SiteFixture';

class FakeJsonExecutor implements ArkWebJsonExecutor {
  private result: string;
  lastScript: string = '';

  constructor(result: string) {
    this.result = result;
  }

  run(script: string): Promise<string> {
    this.lastScript = script;
    return Promise.resolve(this.result);
  }
}

export default function arkWebNetworkBridgeTest() {
  describe('arkWebNetworkBridgeTest', () => {
    // 这个套件原先**没钉站点**,于是除第一条(本来就该在「无站点」下跑)之外全部被桥的
    // `HAS_ACTIVE_SITE` 早退拦掉:注入的 executor 根本没被调用,断言拿到空串/0。
    // 3 条用例因此红了三个月,还被误记成「只能在真机跑」—— 它注入的是 FakeJsonExecutor,
    // 不碰任何设备能力,缺的只是站点这个进程级全局态。
    //
    // 钉站点按用例做而不是放进 beforeAll:第一条要的正是「没有站点」这一态。
    // pinLinuxDo 幂等,重复调用不会把已钉的值当成原值存下来。
    afterAll(() => SiteFixture.restore());

    // 无站点时**不发请求**,并给出可区分的一档:用户该去「添加论坛」,不是检查网络。
    it('returnsNoActiveSiteFailureBeforeSendingAnything', 0, async () => {
      const bridge: ArkWebNetworkBridge = new ArkWebNetworkBridge();
      const result: NetworkResult<string> = await bridge.getJson('/latest.json');

      expect(result.success).assertFalse();
      expect(result.statusCode).assertEqual(0);
      expect(result.challengeState).assertEqual(ChallengeState.NONE);
      expect(result.error?.code).assertEqual(NetworkErrorCode.NETWORK_FAILURE);
      expect(result.error?.requiresChallenge).assertFalse();
      // 界面靠 failureKind 区分「没选论坛」与「断网」。这一档**只标 kind 不标 userReason**:
      // 两个都标会让分类层先命中 USER_REASON,NO_ACTIVE_SITE 永远走不到(文案一样,看不出来)。
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.NO_ACTIVE_SITE);
      expect(result.error?.userReason).assertUndefined();
    });

    // 选了论坛但 executor 还没挂上:这是「请求环境正在准备」,不是网络错误。
    it('returnsHostNotReadyFailureWhenExecutorMissing', 0, async () => {
      SiteFixture.pinLinuxDo();
      const bridge: ArkWebNetworkBridge = new ArkWebNetworkBridge();
      const result: NetworkResult<string> = await bridge.getJson('/latest.json');

      expect(result.success).assertFalse();
      expect(result.statusCode).assertEqual(0);
      expect(result.error?.code).assertEqual(NetworkErrorCode.NETWORK_FAILURE);
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.HOST_NOT_READY);
    });

    it('returnsJsonBodyFromArkWebExecutor', 0, async () => {
      SiteFixture.pinLinuxDo();
      const executor: FakeJsonExecutor = new FakeJsonExecutor('{"statusCode":200,"contentType":"application/json","body":"{\\"topic_list\\":{\\"topics\\":[]}}"}');
      const bridge: ArkWebNetworkBridge = new ArkWebNetworkBridge();
      bridge.setExecutor(executor);

      const result: NetworkResult<string> = await bridge.getJson('/latest.json');

      expect(executor.lastScript).assertContain('/latest.json');
      expect(result.success).assertTrue();
      expect(result.statusCode).assertEqual(200);
      expect(result.challengeState).assertEqual(ChallengeState.NONE);
      expect(result.data).assertEqual('{"topic_list":{"topics":[]}}');
    });

    it('returnsChallengeRequiredForCloudflareHtml', 0, async () => {
      SiteFixture.pinLinuxDo();
      const executor: FakeJsonExecutor = new FakeJsonExecutor('{"statusCode":403,"contentType":"text/html","body":"<html><title>Just a moment...</title><body>cf-chl</body></html>"}');
      const bridge: ArkWebNetworkBridge = new ArkWebNetworkBridge();
      bridge.setExecutor(executor);

      const result: NetworkResult<string> = await bridge.getJson('/latest.json');

      expect(result.success).assertFalse();
      expect(result.statusCode).assertEqual(403);
      expect(result.challengeState).assertEqual(ChallengeState.REQUIRED);
      expect(result.error?.code).assertEqual(NetworkErrorCode.CHALLENGE_REQUIRED);
      expect(result.error?.requiresChallenge).assertTrue();
    });

    it('publishesChallengeEventForCloudflareHtml', 0, async () => {
      SiteFixture.pinLinuxDo();
      const executor: FakeJsonExecutor = new FakeJsonExecutor('{"statusCode":403,"contentType":"text/html","body":"<html><title>Just a moment...</title><body>cf-chl</body></html>"}');
      const bridge: ArkWebNetworkBridge = new ArkWebNetworkBridge();
      let receivedSource: string = '';
      let receivedStatusCode: number = 0;
      let receivedChallengeState: ChallengeState = ChallengeState.NONE;
      const unsubscribe: () => void = ChallengeEventBus.subscribe((event: ChallengeRequiredEvent) => {
        receivedSource = event.source;
        receivedStatusCode = event.statusCode;
        receivedChallengeState = event.challengeState;
      });
      bridge.setExecutor(executor);

      await bridge.getJson('/latest.json');
      unsubscribe();

      expect(receivedSource).assertEqual('/latest.json');
      expect(receivedStatusCode).assertEqual(403);
      expect(receivedChallengeState).assertEqual(ChallengeState.REQUIRED);
    });

    it('canSuppressChallengeEventForInternalProbe', 0, async () => {
      SiteFixture.pinLinuxDo();
      const executor: FakeJsonExecutor = new FakeJsonExecutor('{"statusCode":403,"contentType":"text/html","body":"<html><title>Just a moment...</title><body>cf-chl</body></html>"}');
      const bridge: ArkWebNetworkBridge = new ArkWebNetworkBridge();
      let receivedSource: string = '';
      const unsubscribe: () => void = ChallengeEventBus.subscribe((event: ChallengeRequiredEvent) => {
        receivedSource = event.source;
      });
      bridge.setExecutor(executor);

      await bridge.getJson('/latest.json', { notifyChallenge: false });
      unsubscribe();

      expect(receivedSource).assertEqual('');
    });
  });
}
