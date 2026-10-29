import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { SiteFixture } from './SiteFixture';
import { DraftService } from '../main/ets/services/draft/DraftService';
import { DraftState, SaveReplyDraftInput } from '../main/ets/services/draft/DraftService';
import { DraftEventBus } from '../main/ets/services/draft/DraftEventBus';
import {
  ChallengeState,
  JsonNetworkClient,
  JsonRequestOptions,
  NetworkResult
} from '../main/ets/services/network/NetworkTypes';

class FakeBridge implements JsonNetworkClient {
  private result: NetworkResult<string>;
  requestedPath: string = '';
  requestedBody: string = '';
  requestedReferrer: string = '';

  constructor(result: NetworkResult<string>) {
    this.result = result;
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  deleteForm(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    this.requestedPath = path;
    this.requestedBody = body;
    this.requestedReferrer = options?.referrer ? options.referrer : '';
    return Promise.resolve(this.result);
  }

  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }
}

function ok(payload: string): NetworkResult<string> {
  return { success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: payload };
}

function fail(statusCode: number, payload: string): NetworkResult<string> {
  return { success: false, statusCode: statusCode, challengeState: ChallengeState.NONE, data: payload };
}

/**
 * 按动词排队回包的假桥:保存草稿要验「撞 409 之后补发了几次、第二次的 force_save 是什么」,
 * 删除要验「发没发、带的序号是谁的」——这些都取决于**同一次调用里的第几跳**,
 * 原来那个 FakeBridge 只会对每个请求回同一份结果,记不了次序。
 */
class ScriptedBridge implements JsonNetworkClient {
  postBodies: string[] = [];
  deleteBodies: string[] = [];
  getPaths: string[] = [];
  private postResults: NetworkResult<string>[];
  private getResults: NetworkResult<string>[];
  private deleteResults: NetworkResult<string>[];
  private postIndex: number = 0;
  private getIndex: number = 0;
  private deleteIndex: number = 0;

  constructor(postResults: NetworkResult<string>[], getResults: NetworkResult<string>[],
    deleteResults: NetworkResult<string>[]) {
    this.postResults = postResults;
    this.getResults = getResults;
    this.deleteResults = deleteResults;
  }

  private next(queue: NetworkResult<string>[], index: number): NetworkResult<string> {
    // 队列走完就回一个无害的成功,免得测试因为多问一跳而莫名其妙地红。
    if (index >= queue.length) {
      return ok('{"success":"OK"}');
    }
    return queue[index];
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    this.getPaths.push(path);
    const result: NetworkResult<string> = this.next(this.getResults, this.getIndex);
    this.getIndex += 1;
    return Promise.resolve(result);
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.postBodies.push(`${path} ${body}`);
    const result: NetworkResult<string> = this.next(this.postResults, this.postIndex);
    this.postIndex += 1;
    return Promise.resolve(result);
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    return this.postForm(path, body);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    return Promise.resolve(ok('{}'));
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(ok('{}'));
  }

  deleteForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.deleteBodies.push(`${path} ${body}`);
    const result: NetworkResult<string> = this.next(this.deleteResults, this.deleteIndex);
    this.deleteIndex += 1;
    return Promise.resolve(result);
  }

  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    return Promise.resolve(ok('{}'));
  }
}

function replyInput(sequence: number): SaveReplyDraftInput {
  const input: SaveReplyDraftInput = {
    draftKey: 'topic_42',
    sequence: sequence,
    categoryId: 5,
    reply: '那段已经发出去的回复',
    composerTimeMs: 0,
    typingTimeMs: 0
  };
  return input;
}

export default function draftServiceTest() {
  describe('draftServiceTest', () => {
    beforeAll(() => SiteFixture.pinLinuxDo());

    afterAll(() => SiteFixture.restore());

    it('sequenceConflictIsRetriedOnceWithForceSave', 0, async () => {
      // 上游 Draft#set 对已存在的草稿要求序号**完全相等**,不等就 409,且控制器的自愈只在
      // 行不存在时生效 —— 真机日志里 00:17:19 / 00:17:22 连吃两次 409 之后自动保存从此死掉。
      // force_save=true 时上游改用服务端的 current 作基线再 +1,一次就把两边对齐。
      const bridge: ScriptedBridge = new ScriptedBridge(
        [fail(409, '{"errors":["草稿错误"]}'), ok('{"success":"OK","draft_sequence":6}')],
        [],
        []
      );
      const result: NetworkResult<number> = await new DraftService(bridge).saveReplyDraft(replyInput(5));

      expect(bridge.postBodies.length).assertEqual(2);
      expect(bridge.postBodies[0].indexOf('force_save=false') >= 0).assertTrue();
      expect(bridge.postBodies[1].indexOf('force_save=true') >= 0).assertTrue();
      // 第二次仍带着那个过期序号:force_save 分支里服务端根本不读它。
      expect(bridge.postBodies[1].indexOf('sequence=5') >= 0).assertTrue();
      expect(result.success).assertTrue();
      expect(result.data).assertEqual(6);
    });

    it('otherFailuresAreNotRetried', 0, async () => {
      // 只对 409 补发:限流/过大/未登录那些重试也没用,还会多打一次写入。
      const bridge: ScriptedBridge = new ScriptedBridge(
        [fail(403, '{"errors":["草稿过多"]}'), ok('{"success":"OK","draft_sequence":7}')],
        [],
        []
      );
      const result: NetworkResult<number> = await new DraftService(bridge).saveReplyDraft(replyInput(5));

      expect(bridge.postBodies.length).assertEqual(1);
      expect(result.success).assertFalse();
      expect(result.statusCode).assertEqual(403);
    });

    it('stateReadTellsWhetherARowExists', 0, async () => {
      const empty: ScriptedBridge = new ScriptedBridge([], [ok('{"draft":null,"draft_sequence":0}')], []);
      const none: NetworkResult<DraftState> = await new DraftService(empty).getDraftState('topic_42');
      expect(empty.getPaths[0]).assertEqual('/drafts/topic_42.json');
      expect(none.success).assertTrue();
      expect(none.data?.exists).assertFalse();

      const present: ScriptedBridge = new ScriptedBridge([], [ok('{"draft":"x","draft_sequence":9}')], []);
      const some: NetworkResult<DraftState> = await new DraftService(present).getDraftState('topic_42');
      expect(some.data?.exists).assertTrue();
      expect(some.data?.sequence).assertEqual(9);
    });

    it('deleteUsesTheServersSequenceNotLocals', 0, async () => {
      // 本地攥着一个过期序号(5),服务端现状是 9 → 必须按 9 删。按 5 删会静默落空却回 OK。
      const bridge: ScriptedBridge = new ScriptedBridge(
        [],
        [ok('{"draft":"x","draft_sequence":9}')],
        [ok('{"success":"OK"}')]
      );
      const result: NetworkResult<boolean> = await new DraftService(bridge).deleteDraftByServerState('topic_42');

      expect(bridge.deleteBodies.length).assertEqual(1);
      expect(bridge.deleteBodies[0]).assertEqual(
        '/drafts/topic_42.json draft_key=topic_42&sequence=9');
      expect(result.success).assertTrue();
      expect(result.data).assertTrue();
    });

    it('firstSaveWithSequenceZeroIsStillDeleted', 0, async () => {
      // 这条锁死一个真实踩过的坑:新 key 的**首次**保存走 INSERT 分支,回的序号就是 0
      // (draft_sequences 还没行,DraftSequence.current 也是 0)。曾经按「序号 > 0 才值得删」
      // 拦过一道,于是「只自动存过一次就点发送」这个最常见的情形漏删,草稿箱留下已发出的内容。
      const bridge: ScriptedBridge = new ScriptedBridge(
        [],
        [ok('{"draft":"x","draft_sequence":0}')],
        [ok('{"success":"OK"}')]
      );
      const result: NetworkResult<boolean> = await new DraftService(bridge).deleteDraftByServerState('topic_42');

      expect(bridge.deleteBodies.length).assertEqual(1);
      expect(bridge.deleteBodies[0].indexOf('sequence=0') >= 0).assertTrue();
      expect(result.data).assertTrue();
    });

    it('nothingIsDeletedWhenServerHasNoRow', 0, async () => {
      const bridge: ScriptedBridge = new ScriptedBridge([], [ok('{"draft":null,"draft_sequence":0}')], []);
      const result: NetworkResult<boolean> = await new DraftService(bridge).deleteDraftByServerState('topic_42');

      // 没行就别发 DELETE:上游对不匹配序号也回 OK,那条请求只会留下一句误导性的「删除成功」。
      expect(bridge.deleteBodies.length).assertEqual(0);
      expect(result.success).assertTrue();
      expect(result.data).assertFalse();
    });

    it('deletesDraftWithKeyAndSequence', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{"success":"OK"}'));
      const service: DraftService = new DraftService(bridge);

      const result: NetworkResult<boolean> =
        await service.deleteDraft('new_private_message_1781604136983', 0);

      expect(bridge.requestedPath).assertEqual('/drafts/new_private_message_1781604136983.json');
      expect(bridge.requestedBody).assertEqual('draft_key=new_private_message_1781604136983&sequence=0');
      expect(bridge.requestedReferrer).assertEqual('https://linux.do/my/activity/drafts');
      expect(result.success).assertTrue();
      expect(result.data).assertTrue();
    });

    it('rejectsDeleteResponseWithoutSuccessConfirmation', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{}'));
      const result: NetworkResult<boolean> = await new DraftService(bridge).deleteDraft('topic_42', 3);

      expect(result.success).assertFalse();
      expect(result.error?.message).assertEqual('站点未确认草稿已删除。');
    });

    it('publishesDraftDeletionToCurrentSubscribersOnly', 0, () => {
      let receivedKey: string = '';
      const unsubscribe: () => void = DraftEventBus.subscribeDeleted((draftKey: string) => {
        receivedKey = draftKey;
      });

      DraftEventBus.notifyDeleted('topic_42');
      expect(receivedKey).assertEqual('topic_42');

      unsubscribe();
      DraftEventBus.notifyDeleted('topic_43');
      expect(receivedKey).assertEqual('topic_42');
    });
  });
}
