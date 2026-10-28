import { describe, it, expect } from '@ohos/hypium';
import {
  ChallengeState, JsonNetworkClient, NetworkFailureKind, NetworkResult
} from '../main/ets/services/network/NetworkTypes';
import { MutePrefs, MuteService } from '../main/ets/services/site/MuteService';

class FakeBridge implements JsonNetworkClient {
  private result: NetworkResult<string>;
  requestedPath: string = '';
  postedPath: string = '';
  postedBody: string = '';

  constructor(result: NetworkResult<string>) {
    this.result = result;
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    this.requestedPath = path;
    return Promise.resolve(this.result);
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    this.postedBody = body;
    return Promise.resolve(this.result);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    return Promise.resolve(this.result);
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    this.postedBody = body;
    return Promise.resolve(this.result);
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    this.postedBody = body;
    return Promise.resolve(this.result);
  }

  deleteForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.postedPath = path;
    this.postedBody = body;
    return Promise.resolve(this.result);
  }

  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }
}

function ok(data: string): NetworkResult<string> {
  return { success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: data };
}

export default function muteServiceTest() {
  describe('muteServiceTest', () => {
    // 当前静音态来自 /u/{username}.json 的 user.muted_category_ids / user.muted_tags。
    // 脏值(非数字 id / 空标签)在这里就滤掉,别让它们变成界面上的空行。
    it('readsMutedPrefsFromUserJson', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok(JSON.stringify({
        user: { muted_category_ids: [3, 0, 7], muted_tags: ['抽奖', '', 'linux'] }
      })));
      const result: NetworkResult<MutePrefs> = await new MuteService(bridge).loadPrefs(' alice ');

      expect(result.success).assertTrue();
      expect(bridge.requestedPath).assertEqual('/u/alice.json');
      expect(result.data?.categoryIds.join(',')).assertEqual('3,7');
      expect(result.data?.tags.join(',')).assertEqual('抽奖,linux');
    });

    it('treatsMissingFieldsAsEmpty', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{"user":{}}'));
      const result: NetworkResult<MutePrefs> = await new MuteService(bridge).loadPrefs('alice');
      expect(result.success).assertTrue();
      expect(result.data?.categoryIds.length).assertEqual(0);
      expect(result.data?.tags.length).assertEqual(0);
    });

    it('refusesPrefsWithoutUsername', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{}'));
      const result: NetworkResult<MutePrefs> = await new MuteService(bridge).loadPrefs('  ');
      expect(result.success).assertFalse();
      expect(bridge.requestedPath).assertEqual('');
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.LOCAL_ABORT);
    });

    // 版块静音:POST /category/{id}/notifications,notification_level 0=静音 1=正常。
    it('postsCategoryMuteLevel', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{"success":"OK"}'));
      const service: MuteService = new MuteService(bridge);

      const mute: NetworkResult<boolean> = await service.setCategoryMuted(12, true);
      expect(mute.success).assertTrue();
      expect(bridge.postedPath).assertEqual('/category/12/notifications');
      expect(bridge.postedBody).assertEqual('notification_level=0');

      await service.setCategoryMuted(12, false);
      expect(bridge.postedBody).assertEqual('notification_level=1');
    });

    // 标签静音:PUT /tag/{name}/notifications.json(该路由带 format: :json 约束,.json 不能省),
    // 参数是嵌套的 tag_notification[notification_level],方括号必须预编码。
    it('putsTagMuteLevelWithNestedParam', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{}'));
      const service: MuteService = new MuteService(bridge);

      const mute: NetworkResult<boolean> = await service.setTagMuted(' 抽奖 ', true);
      expect(mute.success).assertTrue();
      expect(bridge.postedPath).assertEqual(`/tag/${encodeURIComponent('抽奖')}/notifications.json`);
      expect(bridge.postedBody).assertEqual('tag_notification%5Bnotification_level%5D=0');

      await service.setTagMuted('linux', false);
      expect(bridge.postedPath).assertEqual('/tag/linux/notifications.json');
      expect(bridge.postedBody).assertEqual('tag_notification%5Bnotification_level%5D=1');
    });

    it('refusesEmptyTagNameWithoutSending', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{}'));
      const result: NetworkResult<boolean> = await new MuteService(bridge).setTagMuted('   ', true);
      expect(result.success).assertFalse();
      expect(bridge.postedPath).assertEqual('');
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.LOCAL_ABORT);
    });

    it('forwardsFailureFromServer', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: false, statusCode: 403, challengeState: ChallengeState.NONE,
        error: { code: 'unexpected_response', message: 'forbidden', requiresChallenge: false }
      } as NetworkResult<string>);
      const result: NetworkResult<boolean> = await new MuteService(bridge).setCategoryMuted(3, true);
      expect(result.success).assertFalse();
      expect(result.statusCode).assertEqual(403);
    });
  });
}
