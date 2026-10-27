import { describe, it, expect } from '@ohos/hypium';
import {
  ChallengeState, JsonNetworkClient, JsonRequestOptions, NetworkErrorCode, NetworkResult
} from '../main/ets/services/network/NetworkTypes';
import {
  ANNOUNCE_TOPIC_ID, AnnouncementScanResult, VersionAnnouncementService
} from '../main/ets/services/announce/VersionAnnouncement';

// 假桥:记录每一次请求路径,按 path 关键字回放预置响应。
// 这个套件的核心断言是**请求次数**,所以必须能数清楚发了几个请求。
class RecordingBridge implements JsonNetworkClient {
  paths: string[] = [];
  private topicBody: string;
  private postsBody: string;
  private postsFails: boolean = false;

  constructor(topicBody: string, postsBody: string, postsFails: boolean = false) {
    this.topicBody = topicBody;
    this.postsBody = postsBody;
    this.postsFails = postsFails;
  }

  getJson(path: string, options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    this.paths.push(path);
    const isPosts: boolean = path.indexOf('/posts.json') >= 0;
    if (isPosts && this.postsFails) {
      // 显式声明中间变量:ArkTS 的 arkts-no-untyped-obj-literals 不接受直接返回的字面量。
      const blocked: NetworkResult<string> = {
        success: false,
        statusCode: 429,
        challengeState: ChallengeState.REQUIRED,
        error: {
          code: NetworkErrorCode.CHALLENGE_REQUIRED,
          message: '需要完成可见 Cloudflare 验证后重试。',
          requiresChallenge: true
        }
      };
      return Promise.resolve(blocked);
    }
    const ok: NetworkResult<string> = {
      success: true,
      statusCode: 200,
      challengeState: ChallengeState.NONE,
      data: isPosts ? this.postsBody : this.topicBody
    };
    return Promise.resolve(ok);
  }

  postForm(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    return this.getJson(path, options);
  }

  postJson(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    return this.getJson(path, options);
  }

  putJson(path: string, options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    return this.getJson(path, options);
  }

  putForm(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    return this.getJson(path, options);
  }

  deleteForm(path: string, body: string, options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    return this.getJson(path, options);
  }

  uploadImage(base64: string, fileName: string, mimeType: string,
    options?: JsonRequestOptions): Promise<NetworkResult<string>> {
    return this.getJson('/uploads.json', options);
  }

  postsRequestCount(): number {
    let count: number = 0;
    for (let i: number = 0; i < this.paths.length; i++) {
      if (this.paths[i].indexOf('/posts.json') >= 0) {
        count++;
      }
    }
    return count;
  }
}

// 造一个公告帖响应:stream 是完整楼层 id 列表,posts 是首屏已返回的那几楼。
// 关键点:stream 末尾的楼**不在** posts 里 —— 那才是要补拉的部分。
function topicBody(stream: number[], loadedPosts: string): string {
  return `{"post_stream":{"stream":[${stream.join(',')}],"posts":[${loadedPosts}]}}`;
}

function postJson(id: number, postNumber: number, cooked: string): string {
  return `{"id":${id},"post_number":${postNumber},"cooked":${JSON.stringify(cooked)}}`;
}

function postsBody(posts: string[]): string {
  return `{"post_stream":{"posts":[${posts.join(',')}]}}`;
}

export default function versionAnnouncementTest() {
  describe('versionAnnouncementTest', () => {
    // 这条是本次修复的核心:尾部楼必须**一次批量**取回。
    // 原先一楼一发,冷启动 5 秒内连打 15 个 posts.json,实测直接撞 CF 429 挑战页,
    // 把整个首页拖进过盾流程。请求数 15 → 1 是这次改动的全部意义,必须钉死。
    it('fetchesAllTailPostsInASingleRequest', 0, async () => {
      // 12 楼:前 3 楼在首屏,后 9 楼要补拉。
      const stream: number[] = [101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112];
      const loaded: string[] = [
        postJson(101, 1, '<p>总更新日志</p>'),
        postJson(102, 2, '<p>[v900001] 老版本</p>'),
        postJson(103, 3, '<p>[v900002] 稍新一点</p>')
      ];
      const tail: string[] = [
        postJson(104, 4, '<p>无标记</p>'),
        postJson(105, 5, '<p>无标记</p>'),
        postJson(106, 6, '<p>无标记</p>'),
        postJson(107, 7, '<p>无标记</p>'),
        postJson(108, 8, '<p>无标记</p>'),
        postJson(109, 9, '<p>无标记</p>'),
        postJson(110, 10, '<p>无标记</p>'),
        postJson(111, 11, '<p>[v900010] 当前版本</p>'),
        postJson(112, 12, '<p>无标记</p>')
      ];
      const bridge: RecordingBridge = new RecordingBridge(
        topicBody(stream, loaded.join(',')), postsBody(tail));

      const result: AnnouncementScanResult = await new VersionAnnouncementService(bridge).scan(900010);

      // 一个 topic.json + **一个** posts.json,不能是 9 个。
      expect(bridge.postsRequestCount()).assertEqual(1);
      expect(bridge.paths.length).assertEqual(2);
      expect(result.current !== null).assertTrue();
      expect(result.current?.versionCode).assertEqual(900010);
    });

    // 批量 URL 必须把每个 id 都带上,否则「一次请求」只是少发了、内容还是缺的。
    it('batchRequestCarriesEveryTailId', 0, async () => {
      const stream: number[] = [201, 202, 203, 204];
      const loaded: string[] = [postJson(201, 1, '<p>主帖</p>')];
      const tail: string[] = [
        postJson(202, 2, '<p>a</p>'),
        postJson(203, 3, '<p>b</p>'),
        postJson(204, 4, '<p>c</p>')
      ];
      const bridge: RecordingBridge = new RecordingBridge(
        topicBody(stream, loaded.join(',')), postsBody(tail));

      await new VersionAnnouncementService(bridge).scan(1);

      const postsPath: string = bridge.paths.filter((p: string) => p.indexOf('/posts.json') >= 0)[0];
      expect(postsPath).assertContain(`/t/${ANNOUNCE_TOPIC_ID}/posts.json`);
      expect(postsPath).assertContain('post_ids%5B%5D=202');
      expect(postsPath).assertContain('post_ids%5B%5D=203');
      expect(postsPath).assertContain('post_ids%5B%5D=204');
      // 首屏已有的楼不该重复请求。
      expect(postsPath.indexOf('post_ids%5B%5D=201') < 0).assertTrue();
    });

    // 首屏已经覆盖全部楼层时,一个 posts.json 都不该发。
    it('sendsNoPostsRequestWhenStreamFullyLoaded', 0, async () => {
      const stream: number[] = [301, 302];
      const loaded: string[] = [
        postJson(301, 1, '<p>主帖</p>'),
        postJson(302, 2, '<p>[v900001] 公告</p>')
      ];
      const bridge: RecordingBridge = new RecordingBridge(
        topicBody(stream, loaded.join(',')), postsBody([]));

      const result: AnnouncementScanResult = await new VersionAnnouncementService(bridge).scan(900001);

      expect(bridge.postsRequestCount()).assertEqual(0);
      expect(result.current?.versionCode).assertEqual(900001);
    });

    // 主帖(楼层1)是总更新日志,里面罗列各版本号纯文本,不能被当成某一版公告。
    it('ignoresOpeningPostEvenIfItListsVersions', 0, async () => {
      const stream: number[] = [401, 402];
      const loaded: string[] = [
        postJson(401, 1, '<p>[v900020] [v900021] 更新日志列表</p>'),
        postJson(402, 2, '<p>[v900005] 真正的公告</p>')
      ];
      const bridge: RecordingBridge = new RecordingBridge(
        topicBody(stream, loaded.join(',')), postsBody([]));

      const result: AnnouncementScanResult = await new VersionAnnouncementService(bridge).scan(900020);

      // 主帖被跳过 → 找不到 v900020 的公告;但 v900005 比 900020 低,也不算「有新版」。
      expect(result.current === null).assertTrue();
      expect(result.newer === null).assertTrue();
    });

    // 比当前版本高的公告要能被识别出来(用于「有新版本」提示)。
    it('reportsNewerVersionWhenFound', 0, async () => {
      const stream: number[] = [501, 502];
      const loaded: string[] = [
        postJson(501, 1, '<p>主帖</p>'),
        postJson(502, 2, '<p>[v900099] 未来版本</p>')
      ];
      const bridge: RecordingBridge = new RecordingBridge(
        topicBody(stream, loaded.join(',')), postsBody([]));

      const result: AnnouncementScanResult = await new VersionAnnouncementService(bridge).scan(900010);

      expect(result.newer?.versionCode).assertEqual(900099);
      expect(result.current === null).assertTrue();
    });

    // 补拉被 CF 拦(429)时必须安静降级:公告是锦上添花,不能把首页拖进错误态,更不能抛。
    // 这正是修复前真机上发生的事 —— 区别在于现在只会发生一次。
    it('degradesQuietlyWhenBatchFetchIsBlocked', 0, async () => {
      const stream: number[] = [601, 602, 603];
      const loaded: string[] = [postJson(601, 1, '<p>主帖</p>')];
      const bridge: RecordingBridge = new RecordingBridge(
        topicBody(stream, loaded.join(',')), '', true);

      const result: AnnouncementScanResult = await new VersionAnnouncementService(bridge).scan(900010);

      expect(result.current === null).assertTrue();
      expect(result.newer === null).assertTrue();
      // 即使被拦,也只发一次,不会重试刷屏。
      expect(bridge.postsRequestCount()).assertEqual(1);
    });

    // 一楼层写多个标记时取最大的那个(用于「回顾旧版」这类写法)。
    it('takesHighestMarkerWhenOnePostListsSeveral', 0, async () => {
      const stream: number[] = [701, 702];
      const loaded: string[] = [
        postJson(701, 1, '<p>主帖</p>'),
        postJson(702, 2, '<p>[v900001] 回顾 与 [v900007] 正式</p>')
      ];
      const bridge: RecordingBridge = new RecordingBridge(
        topicBody(stream, loaded.join(',')), postsBody([]));

      const result: AnnouncementScanResult = await new VersionAnnouncementService(bridge).scan(900007);

      expect(result.current?.versionCode).assertEqual(900007);
    });
  });
}
