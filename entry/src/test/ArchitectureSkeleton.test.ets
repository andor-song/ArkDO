import { describe, it, expect } from '@ohos/hypium';
import { AppConstants } from '../main/ets/common/constants/AppConstants';
import { Topic } from '../main/ets/models/Topic';
import { User } from '../main/ets/models/User';
import { ChallengeState, NetworkErrorCode, NetworkResult } from '../main/ets/services/network/NetworkTypes';

export default function architectureSkeletonTest() {
  describe('architectureSkeletonTest', () => {
    it('definesStableAppConstants', 0, () => {
      expect(AppConstants.APP_NAME).assertEqual('ArkDO');
      // 注意：这里不断言 BASE_URL/HOST —— 站点是运行时注入（CurrentSite.setActiveSite），
      // 测试进程的初始站点状态由执行顺序决定（PushSubscriptionKeys 等用例会改它并还原）。
      // 站点契约单独放 derivesSiteAddressesFromInjectedSite 用例里自管 set/还原，见下。
      expect(AppConstants.DEFAULT_TIMEOUT_MS).assertEqual(15000);
      // Cloudflare 需要真实浏览器 UA；cf_clearance 与 UA 绑定，故不能再用自定义标识 UA。
      expect(AppConstants.DEFAULT_USER_AGENT).assertContain('Mozilla/5.0');
      expect(AppConstants.DEFAULT_USER_AGENT).assertContain('Chrome/');
    });

    it('derivesSiteAddressesFromInjectedSite', 0, () => {
      // 站点派生地址应由注入值推导（这是另外 20 余处 BASE_URL 调用的行为契约）。
      // 测试会污染全局单例，用完后清零，避免影响其它用例。
      AppConstants.setActiveSite('https://example.com', 'example.com');
      expect(AppConstants.BASE_URL).assertEqual('https://example.com');
      expect(AppConstants.HOST).assertEqual('example.com');
      expect(AppConstants.HAS_ACTIVE_SITE).assertTrue();
      expect(AppConstants.HOST_BOOTSTRAP_URL).assertEqual('https://example.com/session/csrf.json');
      expect(AppConstants.LOGIN_URL).assertEqual('https://example.com/login');
      expect(AppConstants.CHALLENGE_URL).assertEqual('https://example.com/challenge');
      // 还原，避免单例污染
      AppConstants.setActiveSite('', '');
    });

    it('allowsMinimalTopicAndUserShape', 0, () => {
      const user: User = {
        id: 1,
        username: 'linuxdo_user',
        displayName: 'Linux.do User',
        avatarTemplate: '/user_avatar/linux.do/linuxdo_user/{size}/1_2.png'
      };
      const topic: Topic = new Topic();
      topic.id = 100;
      topic.title = 'ArkDO phase one';
      topic.slug = 'arkdo-phase-one';
      topic.tags = [];
      topic.postsCount = 1;
      topic.replyCount = 0;
      topic.likeCount = 0;
      topic.createdAt = '2026-07-03T00:00:00.000Z';
      topic.lastPostedAt = '2026-07-03T00:00:00.000Z';
      topic.author = user;

      expect(topic.id).assertEqual(100);
      expect(topic.author?.username).assertEqual('linuxdo_user');
    });

    it('definesNetworkResultShape', 0, () => {
      const result: NetworkResult<string> = {
        success: false,
        statusCode: 0,
        challengeState: ChallengeState.NONE,
        error: {
          code: NetworkErrorCode.NOT_IMPLEMENTED,
          message: 'Phase one network bridge is not implemented.',
          requiresChallenge: false
        }
      };

      expect(result.success).assertFalse();
      expect(result.error?.code).assertEqual(NetworkErrorCode.NOT_IMPLEMENTED);
      expect(result.challengeState).assertEqual(ChallengeState.NONE);
    });
  });
}
