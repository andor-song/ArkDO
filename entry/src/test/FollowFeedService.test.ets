import { describe, it, expect } from '@ohos/hypium';
import {
  ChallengeState, JsonNetworkClient, NetworkFailureKind, NetworkResult
} from '../main/ets/services/network/NetworkTypes';
import { FollowFeedPage, FollowFeedService } from '../main/ets/services/follow/FollowFeedService';

class FakeBridge implements JsonNetworkClient {
  private result: NetworkResult<string>;
  requestedPath: string = '';

  constructor(result: NetworkResult<string>) {
    this.result = result;
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    this.requestedPath = path;
    return Promise.resolve(this.result);
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  deleteForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }

  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }
}

function ok(data: string): NetworkResult<string> {
  return { success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: data };
}

export default function followFeedServiceTest() {
  describe('followFeedServiceTest', () => {
    // 关注动态是**楼层流**:同一主题的多条回复各算一条,必须带 post_number 才能定位。
    // 缺楼号/主题的条目直接丢,不让它变成点了没反应的死行。
    it('mapsPostLevelItemsAndDropsBrokenOnes', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok(JSON.stringify({
        posts: [
          {
            id: 11, topic_id: 5, post_number: 3, created_at: '2026-10-28T10:00:00.000Z',
            excerpt: '一句话摘要', user: { username: 'bob', name: 'Bob' },
            topic: { id: 5, title: '主题标题', slug: 'topic-slug' }
          },
          { id: 12, topic_id: 5, post_number: 0, user: { username: 'bob' } },
          { id: 13, topic_id: 0, post_number: 2 }
        ],
        has_more: true
      })));
      const result: NetworkResult<FollowFeedPage> = await new FollowFeedService(bridge).load('alice');

      expect(result.success).assertTrue();
      expect(bridge.requestedPath).assertEqual('/follow/posts/alice');
      expect(result.data?.items.length).assertEqual(1);
      expect(result.data?.items[0].postNumber).assertEqual(3);
      expect(result.data?.items[0].topicId).assertEqual(5);
      expect(result.data?.items[0].title).assertEqual('主题标题');
      expect(result.data?.items[0].slug).assertEqual('topic-slug');
      expect(result.data?.items[0].username).assertEqual('bob');
      expect(result.data?.items[0].displayName).assertEqual('Bob');
      expect(result.data?.hasMore).assertTrue();
    });

    // 翻页是 created_before 游标(服务端按时间倒序),不是页码。
    it('paginatesByCreatedBeforeCursor', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{"posts":[],"has_more":false}'));
      const cursor: string = '2026-10-28T10:00:00.000Z';
      const result: NetworkResult<FollowFeedPage> =
        await new FollowFeedService(bridge).load('alice', cursor);

      expect(result.success).assertTrue();
      expect(bridge.requestedPath)
        .assertEqual(`/follow/posts/alice?created_before=${encodeURIComponent(cursor)}`);
      expect(result.data?.hasMore).assertFalse();
    });

    it('refusesEmptyUsernameWithoutSending', 0, async () => {
      const bridge: FakeBridge = new FakeBridge(ok('{}'));
      const result: NetworkResult<FollowFeedPage> = await new FollowFeedService(bridge).load('   ');
      expect(result.success).assertFalse();
      expect(bridge.requestedPath).assertEqual('');
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.LOCAL_ABORT);
    });
  });
}
