import { describe, it, expect } from '@ohos/hypium';
import {
  ChallengeState, JsonNetworkClient, NetworkFailureKind, NetworkResult
} from '../main/ets/services/network/NetworkTypes';
import { UserCard, UserCardService } from '../main/ets/services/user/UserCardService';

class FakeBridge implements JsonNetworkClient {
  private result: NetworkResult<string>;
  requestedPath: string = '';
  postedPath: string = '';

  constructor(result: NetworkResult<string>) {
    this.result = result;
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    this.requestedPath = path;
    return Promise.resolve(this.result);
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    return Promise.resolve(this.result);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    return Promise.resolve(this.result);
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    return Promise.resolve(this.result);
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    return Promise.resolve(this.result);
  }

  deleteForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    return Promise.resolve(this.result);
  }

  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }
}

function ok(data: string): NetworkResult<string> {
  return { success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: data };
}

export default function userCardServiceTest() {
  describe('userCardServiceTest', () => {
    // 卡片数据源必须是 card.json:can_follow / is_followed 只加在 user_card 序列化器上。
    it('loadsCardWithFollowState', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok(JSON.stringify({
        user: { username: 'bob', name: 'Bob', avatar_template: '/u/bob/{size}.png' },
        bio_excerpt: '  一句简介  ',
        post_count: 12, topic_count: 3, likes_received: 45,
        total_followers: 7, total_following: 9,
        can_follow: true, is_followed: false, can_send_private_message_to_user: true
      })));
      const result: NetworkResult<UserCard> = await new UserCardService(bridge).load(' bob ');

      expect(result.success).assertTrue();
      expect(bridge.requestedPath).assertEqual('/u/bob/card.json');
      expect(result.data?.username).assertEqual('bob');
      expect(result.data?.bioExcerpt).assertEqual('一句简介');
      expect(result.data?.postCount).assertEqual(12);
      expect(result.data?.canFollow).assertTrue();
      expect(result.data?.isFollowed).assertFalse();
      expect(result.data?.canSendPrivateMessage).assertTrue();
    });

    it('treatsMissingFlagsAsFalse', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{"user":{"username":"bob"}}'));
      const result: NetworkResult<UserCard> = await new UserCardService(bridge).load('bob');
      expect(result.data?.canFollow).assertFalse();
      expect(result.data?.isFollowed).assertFalse();
      expect(result.data?.bioExcerpt).assertEqual('');
    });

    // 关注 / 取关走插件引擎路由(无 .json 后缀)。
    it('followsAndUnfollowsViaPluginRoutes', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{"success":"OK"}'));
      const service: UserCardService = new UserCardService(bridge);

      const followed: NetworkResult<boolean> = await service.setFollow('bob', true);
      expect(followed.success).assertTrue();
      expect(bridge.postedPath).assertEqual('/follow/bob');

      await service.setFollow('bob', false);
      expect(bridge.postedPath).assertEqual('/follow/bob');
    });

    it('refusesEmptyUsername', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{}'));
      const result: NetworkResult<UserCard> = await new UserCardService(bridge).load('   ');
      expect(result.success).assertFalse();
      expect(bridge.requestedPath).assertEqual('');
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.LOCAL_ABORT);
    });
  });
}
