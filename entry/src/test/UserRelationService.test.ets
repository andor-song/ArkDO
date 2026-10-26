import { describe, it, expect } from '@ohos/hypium';
import { EndorsableCategoriesResult } from '../main/ets/models/UserProfile';
import {
  USER_RELATION_IGNORED,
  USER_RELATION_MUTED,
  USER_RELATION_NORMAL,
  UserRelationService,
  buildUserRelationOptions,
  expiringAtFromNow,
  userRelationStateOf
} from '../main/ets/services/user/UserRelationService';
import { ChallengeState, JsonNetworkClient, NetworkResult } from '../main/ets/services/network/NetworkTypes';

// 记录最后一次请求的方法/路径/body:写操作用错 method 或 body 就会误操作,必须锁死。
class SpyBridge implements JsonNetworkClient {
  private result: NetworkResult<string>;
  lastMethod: string = '';
  lastPath: string = '';
  lastBody: string = '';

  constructor(result: NetworkResult<string>) {
    this.result = result;
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    this.lastMethod = 'GET';
    this.lastPath = path;
    return Promise.resolve(this.result);
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.lastMethod = 'POST_FORM';
    this.lastPath = path;
    this.lastBody = body;
    return Promise.resolve(this.result);
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    this.lastMethod = 'POST';
    this.lastPath = path;
    this.lastBody = body;
    return Promise.resolve(this.result);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    this.lastMethod = 'PUT';
    this.lastPath = path;
    return Promise.resolve(this.result);
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.lastMethod = 'PUT_FORM';
    this.lastPath = path;
    this.lastBody = body;
    return Promise.resolve(this.result);
  }

  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    // 接口占位:本套测试不触及图片上传,只为满足 JsonNetworkClient 而实现。
    this.lastMethod = 'UPLOAD_IMAGE';
    return Promise.resolve(this.result);
  }

  deleteForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.lastMethod = 'DELETE_FORM';
    this.lastPath = path;
    this.lastBody = body;
    return Promise.resolve(this.result);
  }
}

function okResponse(payload: string): NetworkResult<string> {
  return { success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: payload };
}

export default function userRelationServiceTest() {
  describe('userRelationServiceTest', () => {
    // 关注:PUT /follow/{u}.json 空 body(对齐官网 content-length:0)。
    it('followUserPutsToFollowEndpoint', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{"success":"OK"}'));
      const service: UserRelationService = new UserRelationService(bridge);

      const result: NetworkResult<boolean> = await service.followUser('kevin');

      expect(bridge.lastMethod).assertEqual('PUT');
      expect(bridge.lastPath).assertEqual('/follow/kevin.json');
      expect(result.success).assertTrue();
      expect(result.data).assertEqual(true);
    });

    // 取消关注:DELETE 同一端点。用错成 PUT 就会变成「再次关注」。
    it('unfollowUserDeletesFollowEndpoint', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{"success":"OK"}'));
      const service: UserRelationService = new UserRelationService(bridge);

      await service.unfollowUser('kevin');

      expect(bridge.lastMethod).assertEqual('DELETE_FORM');
      expect(bridge.lastPath).assertEqual('/follow/kevin.json');
    });

    // 认可分类列表:形状取自 /category-experts/endorsable-categories 实测响应。
    it('parsesEndorsableCategoriesAndRemaining', 0, async () => {
      const payload: string = '{"categories":[' +
        '{"id":32,"name":"读书成诗","color":"e0d900"},' +
        '{"id":4,"name":"开发调优","color":"32c3c3"},' +
        // 缺 name 的条目丢弃。
        '{"id":99}],' +
        '"extras":{"remaining_endorsements":2}}';
      const bridge: SpyBridge = new SpyBridge(okResponse(payload));
      const service: UserRelationService = new UserRelationService(bridge);

      const result: NetworkResult<EndorsableCategoriesResult> = await service.getEndorsableCategories('kevin');

      expect(bridge.lastMethod).assertEqual('GET');
      expect(bridge.lastPath).assertEqual('/category-experts/endorsable-categories/kevin.json');
      expect(result.success).assertTrue();
      expect(result.data?.categories.length).assertEqual(2);
      expect(result.data?.categories[0].name).assertEqual('读书成诗');
      expect(result.data?.categories[1].id).assertEqual(4);
      expect(result.data?.remainingEndorsements).assertEqual(2);
    });

    // 提交认可:PUT + form body categoryIds[]=N,多选用 & 连接。body 写错服务端认可到别的分类。
    it('endorsePutsCategoryIdsAsFormBody', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{"category_expert_endorsements":[{"id":1,"category_id":4}]}'));
      const service: UserRelationService = new UserRelationService(bridge);

      const result: NetworkResult<boolean> = await service.endorseCategories('kevin', [4, 11]);

      expect(bridge.lastMethod).assertEqual('PUT_FORM');
      expect(bridge.lastPath).assertEqual('/category-experts/endorse/kevin.json');
      expect(bridge.lastBody).assertEqual('categoryIds[]=4&categoryIds[]=11');
      expect(result.success).assertTrue();
    });

    // 空选择不发请求:防止「认可」按钮误触发一次空提交。
    it('endorseWithNoCategoriesDoesNotRequest', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{}'));
      const service: UserRelationService = new UserRelationService(bridge);

      const result: NetworkResult<boolean> = await service.endorseCategories('kevin', []);

      expect(result.success).assertFalse();
      // 没有触达 bridge:方法记录仍是初始空串。
      expect(bridge.lastMethod).assertEqual('');
    });

    // ---- 静音 / 忽略 ----

    // 端点与官方前端逐字一致：PUT /u/{u}/notification_level.json（userPath + .json）。
    it('mutesViaNotificationLevelEndpoint', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{"success":"OK"}'));
      const result = await new UserRelationService(bridge).setUserRelation('kavingo', USER_RELATION_MUTED, '');

      expect(bridge.lastMethod).assertEqual('PUT_FORM');
      expect(bridge.lastPath).assertEqual('/u/kavingo/notification_level.json');
      expect(bridge.lastBody).assertEqual('notification_level=mute');
      expect(result.success).assertTrue();
    });

    // 「恢复」由服务端两个都清，客户端只发一个 normal，不去串两次请求。
    it('sendsNormalWithoutExpiry', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{"success":"OK"}'));
      await new UserRelationService(bridge).setUserRelation('a.b', USER_RELATION_NORMAL, '');

      expect(bridge.lastPath).assertEqual('/u/a.b/notification_level.json');
      expect(bridge.lastBody).assertEqual('notification_level=normal');
    });

    // 上游 ignored_users.expiring_at 是 NOT NULL，参数缺失会在 Time.parse(nil) 抛 500。
    // 所以 ignore 缺到期时间必须**在客户端拒发**，而不是发一个注定失败的请求。
    it('refusesIgnoreWithoutExpiry', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{"success":"OK"}'));
      const result = await new UserRelationService(bridge).setUserRelation('x', USER_RELATION_IGNORED, '');

      expect(bridge.lastMethod).assertEqual('');
      expect(result.success).assertFalse();
    });

    it('ignoreCarriesUrlEncodedExpiry', 0, async () => {
      const bridge: SpyBridge = new SpyBridge(okResponse('{"success":"OK"}'));
      await new UserRelationService(bridge).setUserRelation('x', USER_RELATION_IGNORED, '2026-11-01T00:00:00.000Z');

      expect(bridge.lastBody)
        .assertEqual('notification_level=ignore&expiring_at=2026-11-01T00%3A00%3A00.000Z');
    });

    // 到期时间用 UTC ISO：上游 Time.parse / DateTime.parse 都吃，且不引入本地时区歧义。
    it('expiringAtIsUtcIsoPlusDays', 0, () => {
      const base: number = Date.UTC(2026, 9, 27, 0, 0, 0);
      expect(expiringAtFromNow(base, 3)).assertEqual('2026-10-30T00:00:00.000Z');
      expect(expiringAtFromNow(base, 0)).assertEqual('2026-10-27T00:00:00.000Z');
    });

    // 上游给的是两个独立布尔；这里收敛成三态，且 ignored 优先（服务端互斥，
    // 万一历史数据同时为真也不能让 UI 出现"既忽略又静音"）。
    it('collapsesTwoBooleansIntoOneState', 0, () => {
      expect(userRelationStateOf(undefined, undefined)).assertEqual(USER_RELATION_NORMAL);
      expect(userRelationStateOf(false, false)).assertEqual(USER_RELATION_NORMAL);
      expect(userRelationStateOf(false, true)).assertEqual(USER_RELATION_MUTED);
      expect(userRelationStateOf(true, false)).assertEqual(USER_RELATION_IGNORED);
      expect(userRelationStateOf(true, true)).assertEqual(USER_RELATION_IGNORED);
    });

    // 权限位决定入口：没有 can_mute/can_ignore 时只剩「恢复」一行（不能凭空给入口）。
    it('optionsFollowServerPermissionFlags', 0, () => {
      expect(buildUserRelationOptions(USER_RELATION_NORMAL, false, false).length).assertEqual(1);
      expect(buildUserRelationOptions(USER_RELATION_NORMAL, true, false).length).assertEqual(2);
      const ignoreOnly = buildUserRelationOptions(USER_RELATION_NORMAL, false, true);
      expect(ignoreOnly.length).assertEqual(5);
      expect(buildUserRelationOptions(USER_RELATION_NORMAL, true, true).length).assertEqual(6);
    });

    // 「忽略」不给任何一行打勾：服务端不告诉剩余天数，标在哪一行都是撒谎的勾选。
    it('neverClaimsACurrentIgnoreDuration', 0, () => {
      const options = buildUserRelationOptions(USER_RELATION_IGNORED, true, true);
      let checked: number = 0;
      for (let index: number = 0; index < options.length; index++) {
        if (options[index].current) {
          checked++;
        }
      }
      expect(checked).assertEqual(0);
      const muted = buildUserRelationOptions(USER_RELATION_MUTED, true, true);
      let mutedChecked: number = 0;
      for (let index: number = 0; index < muted.length; index++) {
        if (muted[index].current) {
          mutedChecked++;
        }
      }
      expect(mutedChecked).assertEqual(1);
    });
  });
}
