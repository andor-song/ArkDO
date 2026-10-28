import { describe, it, expect } from '@ohos/hypium';
import { TopicPage, TopicPostHit, TopicService } from '../main/ets/services/topic/TopicService';
import { Topic } from '../main/ets/models/Topic';
import { TopicDetail } from '../main/ets/models/TopicDetail';
import {
  ChallengeState, JsonNetworkClient, NetworkErrorCode, NetworkFailureKind, NetworkResult
} from '../main/ets/services/network/NetworkTypes';

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

  // 接口占位:本套测试不触及图片上传,只为满足 JsonNetworkClient 而实现。
  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    return Promise.resolve(this.result);
  }
}

class SequenceBridge implements JsonNetworkClient {
  private results: NetworkResult<string>[];
  requestedPaths: string[] = [];
  private index: number = 0;

  constructor(results: NetworkResult<string>[]) {
    this.results = results;
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    this.requestedPaths.push(path);
    const result: NetworkResult<string> = this.results[this.index];
    this.index++;
    return Promise.resolve(result);
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.requestedPaths.push(path);
    const result: NetworkResult<string> = this.results[this.index];
    this.index++;
    return Promise.resolve(result);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    this.requestedPaths.push(path);
    const result: NetworkResult<string> = this.results[this.index];
    this.index++;
    return Promise.resolve(result);
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    this.requestedPaths.push(path);
    const result: NetworkResult<string> = this.results[this.index];
    this.index++;
    return Promise.resolve(result);
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.requestedPaths.push(path);
    const result: NetworkResult<string> = this.results[this.index];
    this.index++;
    return Promise.resolve(result);
  }

  // 接口占位:本套测试不触及图片上传,只为满足 JsonNetworkClient 而实现。
  // 与其它方法一致从序列取值,避免误用时静默返回错位的结果。
  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    const result: NetworkResult<string> = this.results[this.index];
    this.index++;
    return Promise.resolve(result);
  }

  deleteForm(path: string, body: string): Promise<NetworkResult<string>> {
    this.requestedPaths.push(path);
    const result: NetworkResult<string> = this.results[this.index];
    this.index++;
    return Promise.resolve(result);
  }
}

export default function topicServiceTest() {
  describe('topicServiceTest', () => {
    it('loadsLatestTopicsFromDiscoursePayload', 0, async () => {
      const payload: string = '{"topic_list":{"topics":[{"id":42,"title":"ArkDO 第二阶段","slug":"arkdo-phase-two","category_id":36,"tags":["快问快答",{"name":"高级推广","slug":"1514-tag"}],"posts_count":5,"reply_count":4,"like_count":9,"created_at":"2026-07-03T00:00:00.000Z","last_posted_at":"2026-07-03T00:10:00.000Z","posters":[{"user_id":7,"description":"原始作者"}]}]},"users":[{"id":7,"username":"linuxdo_user","name":"Linux.do User","avatar_template":"/user_avatar/linux.do/linuxdo_user/{size}/1_2.png"}]}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<Topic[]> = await service.getLatestTopics();

      expect(bridge.requestedPath).assertEqual('/latest.json');
      expect(result.success).assertTrue();
      expect(result.data?.length).assertEqual(1);
      expect(result.data?.[0].id).assertEqual(42);
      expect(result.data?.[0].title).assertEqual('ArkDO 第二阶段');
      expect(result.data?.[0].categoryId).assertEqual(36);
      expect(result.data?.[0].tags.length).assertEqual(2);
      expect(result.data?.[0].tags[0].name).assertEqual('快问快答');
      expect(result.data?.[0].tags[1].name).assertEqual('高级推广');
      expect(result.data?.[0].tags[1].slug).assertEqual('1514-tag');
      expect(result.data?.[0].postsCount).assertEqual(5);
      expect(result.data?.[0].replyCount).assertEqual(4);
      expect(result.data?.[0].author?.username).assertEqual('linuxdo_user');
    });

    it('loadsIncomingLatestTopicsByUniqueIds', 0, async () => {
      const payload: string = '{"topic_list":{"topics":[{"id":42,"title":"更新话题","posts_count":2,"reply_count":1,"like_count":0},{"id":7,"title":"新话题","posts_count":1,"reply_count":0,"like_count":0}]},"users":[]}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<Topic[]> = await service.getLatestTopicsByIds([42, 7, 42]);

      expect(bridge.requestedPath).assertEqual('/latest.json?topic_ids=42,7');
      expect(result.success).assertTrue();
      expect(result.data?.length).assertEqual(2);
      expect(result.data?.[0].id).assertEqual(42);
      expect(result.data?.[1].id).assertEqual(7);
    });

    it('loadsAllIncomingTopicIdsInOneRequest', 0, async () => {
      const ids: number[] = [];
      for (let id: number = 1; id <= 65; id++) {
        ids.push(id);
      }
      const bridge: SequenceBridge = new SequenceBridge([{
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: '{"topic_list":{"topics":[{"id":65,"title":"服务端第一条"},{"id":1,"title":"服务端第二条"}]},"users":[]}'
      }]);
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<Topic[]> = await service.getLatestTopicsByIds(ids);

      expect(bridge.requestedPaths.length).assertEqual(1);
      expect(bridge.requestedPaths[0]).assertEqual(`/latest.json?topic_ids=${ids.join(',')}`);
      expect(result.success).assertTrue();
      expect(result.data?.length).assertEqual(2);
      expect(result.data?.[0].id).assertEqual(65);
      expect(result.data?.[1].id).assertEqual(1);
    });

    it('usesFirstPosterUserIdAsTopicAuthor', 0, async () => {
      const payload: string = '{"topic_list":{"topics":[{"id":43,"title":"中文 poster 描述","posts_count":1,"reply_count":0,"like_count":0,"posters":[{"user_id":8,"description":"原始作者"},{"user_id":9,"description":"最近回复"}]}]},"users":[{"id":8,"username":"first_user","name":"First User","avatar_template":"/first/{size}.png"},{"id":9,"username":"wrong_user","name":"Wrong User","avatar_template":"/wrong/{size}.png"}]}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<Topic[]> = await service.getLatestTopics();

      expect(result.success).assertTrue();
      expect(result.data?.[0].author?.id).assertEqual(8);
      expect(result.data?.[0].author?.username).assertEqual('first_user');
    });

    it('returnsUnexpectedResponseForInvalidTopicPayload', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: '{"topic_list":{}}'
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<Topic[]> = await service.getLatestTopics();

      expect(result.success).assertFalse();
      expect(result.statusCode).assertEqual(200);
      expect(result.error?.code).assertEqual(NetworkErrorCode.UNEXPECTED_RESPONSE);
    });

    it('preservesChallengeRequiredResult', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: false,
        statusCode: 403,
        challengeState: ChallengeState.REQUIRED,
        error: {
          code: NetworkErrorCode.CHALLENGE_REQUIRED,
          message: 'Cloudflare challenge required.',
          requiresChallenge: true
        }
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<Topic[]> = await service.getLatestTopics();

      expect(result.success).assertFalse();
      expect(result.statusCode).assertEqual(403);
      expect(result.challengeState).assertEqual(ChallengeState.REQUIRED);
      expect(result.error?.requiresChallenge).assertTrue();
    });

    it('loadsPagedLatestTopicsWithMoreFlag', 0, async () => {
      const firstPayload: string = '{"topic_list":{"more_topics_url":"/latest.json?page=1","topics":[{"id":1,"title":"第一页","posts_count":1,"reply_count":0,"like_count":0}]},"users":[]}';
      const secondPayload: string = '{"topic_list":{"topics":[{"id":2,"title":"第二页","posts_count":1,"reply_count":0,"like_count":0}]},"users":[]}';
      const bridge: SequenceBridge = new SequenceBridge([
        {
          success: true,
          statusCode: 200,
          challengeState: ChallengeState.NONE,
          data: firstPayload
        },
        {
          success: true,
          statusCode: 200,
          challengeState: ChallengeState.NONE,
          data: secondPayload
        }
      ]);
      const service: TopicService = new TopicService(bridge);

      const firstPage: NetworkResult<TopicPage> = await service.getLatestTopicsPage(0);
      const secondPage: NetworkResult<TopicPage> = await service.getLatestTopicsPage(1);

      expect(bridge.requestedPaths[0]).assertEqual('/latest.json');
      expect(bridge.requestedPaths[1]).assertEqual('/latest.json?page=1');
      expect(firstPage.success).assertTrue();
      expect(firstPage.data?.topics[0].title).assertEqual('第一页');
      expect(firstPage.data?.page).assertEqual(0);
      expect(firstPage.data?.hasMore).assertTrue();
      expect(secondPage.success).assertTrue();
      expect(secondPage.data?.topics[0].title).assertEqual('第二页');
      expect(secondPage.data?.page).assertEqual(1);
      expect(secondPage.data?.hasMore).assertFalse();
    });

    it('loadsTopicDetailFromDiscoursePayload', 0, async () => {
      const payload: string = '{"id":42,"title":"ArkDO 第二阶段","slug":"arkdo-phase-two","category_id":36,"tags":["快问快答",{"name":"高级推广","slug":"1514-tag"}],"posts_count":2,"reply_count":1,"like_count":3,"views":128,"created_at":"2026-07-03T00:00:00.000Z","post_stream":{"posts":[{"id":100,"topic_id":42,"post_number":1,"username":"alice","name":"Alice","avatar_template":"/user_avatar/linux.do/alice/{size}/1_2.png","created_at":"2026-07-03T00:01:00.000Z","cooked":"<p>Hello <strong>ArkDO</strong>&amp; Linux.do</p>","like_count":2},{"id":101,"topic_id":42,"post_number":2,"username":"bob","name":"Bob","avatar_template":"/user_avatar/linux.do/bob/{size}/1_2.png","created_at":"2026-07-03T00:02:00.000Z","cooked":"<p>第二条回复<br>继续讨论</p>","reply_count":1}]}}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<TopicDetail> = await service.getTopicDetail(42, 'arkdo-phase-two');

      expect(bridge.requestedPath).assertEqual('/t/arkdo-phase-two/42.json');
      expect(result.success).assertTrue();
      expect(result.data?.id).assertEqual(42);
      expect(result.data?.title).assertEqual('ArkDO 第二阶段');
      expect(result.data?.categoryId).assertEqual(36);
      expect(result.data?.tags.length).assertEqual(2);
      expect(result.data?.tags[0].name).assertEqual('快问快答');
      expect(result.data?.tags[1].name).assertEqual('高级推广');
      expect(result.data?.tags[1].slug).assertEqual('1514-tag');
      expect(result.data?.viewCount).assertEqual(128);
      expect(result.data?.posts.length).assertEqual(2);
      expect(result.data?.posts[0].author?.username).assertEqual('alice');
      expect(result.data?.posts[0].plainText).assertEqual('Hello ArkDO& Linux.do');
      expect(result.data?.posts[1].plainText).assertEqual('第二条回复\n继续讨论');
    });

    it('mapsAnimatedAvatarForPostAuthor', 0, async () => {
      const payload: string = '{"id":7,"title":"动图头像","post_stream":{"posts":[{"id":70,"topic_id":7,"post_number":1,"username":"torvalds","name":"Linus","avatar_template":"/user_avatar/linux.do/torvalds/{size}/1_2.png","animated_avatar":"//cdn.ldstatic.com/original/4X/a/b/c.gif","cooked":"<p>hi</p>"}]}}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<TopicDetail> = await service.getTopicDetail(7, 'topic');

      expect(result.success).assertTrue();
      expect(result.data?.posts[0].author?.animatedAvatar).assertEqual('//cdn.ldstatic.com/original/4X/a/b/c.gif');
      expect(result.data?.posts[0].author?.avatarTemplate).assertEqual('/user_avatar/linux.do/torvalds/{size}/1_2.png');
    });

    it('mapsReadStateFromTopicDetailPayload', 0, async () => {
      const payload: string = '{"id":88,"title":"已读状态","last_read_post_number":2,"highest_post_number":3,"unread_posts":1,"post_stream":{"posts":[{"id":1,"topic_id":88,"post_number":1,"username":"a","cooked":"<p>1</p>","read":true},{"id":2,"topic_id":88,"post_number":2,"username":"b","cooked":"<p>2</p>","read":false},{"id":3,"topic_id":88,"post_number":3,"username":"c","cooked":"<p>3</p>"}]}}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<TopicDetail> = await service.getTopicDetail(88);

      expect(result.success).assertTrue();
      expect(result.data?.lastReadPostNumber).assertEqual(2);
      expect(result.data?.highestPostNumber).assertEqual(3);
      expect(result.data?.unreadPosts).assertEqual(1);
      expect(result.data?.posts[0].read).assertEqual(true);
      expect(result.data?.posts[1].read).assertEqual(false);
      // 无 read 字段的楼层保持 undefined,交给水位线兜底。
      expect(result.data?.posts[2].read === undefined).assertTrue();
    });

    // 站点允许的回应集合来自 topic_view 的 valid_reactions(discourse-reactions 插件)。
    // 站点可以在设置里关掉某些表情,写死面板就会摆出点不动的按钮。
    it('mapsValidReactionsFromTopicDetail', 0, async () => {
      const payload: string = '{"id":7,"title":"表情","valid_reactions":["heart","joy",""],"post_stream":{"posts":[{"id":1,"topic_id":7,"post_number":1,"username":"a","cooked":"<p>1</p>"}]}}';
      const bridge: FakeBridge = new FakeBridge({
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: payload
      });

      const result: NetworkResult<TopicDetail> = await new TopicService(bridge).getTopicDetail(7);

      expect(result.success).assertTrue();
      // 空串被滤掉,否则面板里会多一个点了发不出去的空白格。
      expect(result.data?.validReactions?.join(',')).assertEqual('heart,joy');
    });

    it('leavesValidReactionsUndefinedWhenAbsentOrEmpty', 0, async () => {
      const absent: string = '{"id":7,"title":"表情","post_stream":{"posts":[{"id":1,"topic_id":7,"post_number":1,"username":"a","cooked":"<p>1</p>"}]}}';
      const absentResult: NetworkResult<TopicDetail> =
        await new TopicService(new FakeBridge({
          success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: absent
        })).getTopicDetail(7);
      expect(absentResult.data?.validReactions === undefined).assertTrue();

      const empty: string = '{"id":7,"title":"表情","valid_reactions":["",""],"post_stream":{"posts":[{"id":1,"topic_id":7,"post_number":1,"username":"a","cooked":"<p>1</p>"}]}}';
      const emptyResult: NetworkResult<TopicDetail> =
        await new TopicService(new FakeBridge({
          success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: empty
        })).getTopicDetail(7);
      // 全被过滤掉时同样 undefined:组件据此退回内置顺序,而不是渲染一个空面板。
      expect(emptyResult.data?.validReactions === undefined).assertTrue();
    });

    it('encodesTimingsReportAsFormBody', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: ''
      });
      const service: TopicService = new TopicService(bridge);
      const timings: Map<number, number> = new Map();
      timings.set(1, 1001);
      timings.set(2, 3000);

      const result: NetworkResult<string> = await service.reportTimings(2117030, timings, 4001);

      expect(result.success).assertTrue();
      expect(bridge.postedPath).assertEqual('/topics/timings');
      expect(bridge.postedBody).assertEqual('timings%5B1%5D=1001&timings%5B2%5D=3000&topic_time=4001&topic_id=2117030');
    });

    it('loadsReactionUsersPageFromDiscoursePayload', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: '{"users":[{"id":1,"username":"alice","name":"Alice","avatar_template":"/user_avatar/linux.do/alice/{size}/1.png","reaction":"heart"},{"id":2,"username":"bob","reaction":"+1"}],"total_rows":62}'
      });
      const service: TopicService = new TopicService(bridge);

      const result = await service.getReactionUsers(19741741, 2);

      expect(bridge.requestedPath).assertEqual(
        '/discourse-reactions/posts/19741741/reactions-users-list.json?page=2&limit=30'
      );
      expect(result.success).assertTrue();
      expect(result.data?.totalRows).assertEqual(62);
      expect(result.data?.users.length).assertEqual(2);
      expect(result.data?.users[0].displayName).assertEqual('Alice');
      expect(result.data?.users[1].reaction).assertEqual('+1');
    });

    it('rejectsInvalidReactionUsersPayload', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: '{"users":{}}'
      });
      const service: TopicService = new TopicService(bridge);

      const result = await service.getReactionUsers(19741741, 0);

      expect(result.success).assertFalse();
      expect(result.error?.code).assertEqual(NetworkErrorCode.UNEXPECTED_RESPONSE);
    });

    // 改已发主题分类/标签:PUT /posts/{id} 的 form body 里带 topic[category_id]/topic[tags]。
    // tags 是逗号分隔字符串(Discourse TopicUpdater 接受字符串后 split)。
    it('updatePostAppendsTopicCategoryAndTagsWhenGiven', 0, async () => {
      // TopicPost 没有 raw 字段,正文渲染用 cookedHtml(cooked→mapPosts)。
      const payload: string = '{"post":{"id":5,"post_number":1,"topic_id":100,"cooked":"<p>新正文</p>"}}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result = await service.updatePost(5, 100, '新正文', '旧正文', { categoryId: 4, tags: ['公告', 'long'] });

      expect(bridge.postedPath).assertEqual('/posts/5');
      expect(bridge.postedBody).assertEqual(
        'post%5Bedit_reason%5D=&post%5Braw%5D=%E6%96%B0%E6%AD%A3%E6%96%87&post%5Btopic_id%5D=100&' +
        'post%5Boriginal_text%5D=%E6%97%A7%E6%AD%A3%E6%96%87&post%5Blocale%5D=&' +
        'topic%5Bcategory_id%5D=4&topic%5Btags%5D=%E5%85%AC%E5%91%8A%2Clong');
      expect(result.success).assertTrue();
      expect(result.data?.cookedHtml).assertEqual('<p>新正文</p>');
    });

    it('updatePostOmitsTopicFieldsWhenNotGiven', 0, async () => {
      const payload: string = '{"post":{"id":5,"post_number":1,"topic_id":100,"raw":"新正文"}}';
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: payload
      });
      const service: TopicService = new TopicService(bridge);

      const result = await service.updatePost(5, 100, '新正文', '旧正文');

      expect(bridge.postedBody.includes('topic%5B')).assertFalse();
      expect(result.success).assertTrue();
    });

    // ---- 通知等级(关注 / 跟踪 / 正常 / 静默) ----

    it('postsNotificationLevelToTopicNotificationsEndpoint', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: '{"success":"OK"}'
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<boolean> = await service.setNotificationLevel(12345, 3);

      expect(bridge.postedPath).assertEqual('/t/12345/notifications');
      expect(bridge.postedBody).assertEqual('notification_level=3');
      expect(result.success).assertTrue();
      expect(result.data).assertTrue();
    });

    // 越界档位**不发请求**:服务端只做 .to_i 而不校验范围,客户端漏了就是往库里写脏值。
    it('refusesToPostUnknownNotificationLevel', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: true,
        statusCode: 200,
        challengeState: ChallengeState.NONE,
        data: '{"success":"OK"}'
      });
      const service: TopicService = new TopicService(bridge);

      const result: NetworkResult<boolean> = await service.setNotificationLevel(1, 7);

      expect(bridge.postedPath).assertEqual('');
      expect(result.success).assertFalse();
      expect(result.error?.code).assertEqual(NetworkErrorCode.UNEXPECTED_RESPONSE);
    });

    // details.notification_level 必须**原样**透传、不在服务层归一:
    // 一旦被 normalize 成 1,"服务端到底给没给"就永久丢了,顶栏会误挂一个点了只会失败的铃铛。
    it('mapsNotificationLevelFromTopicDetailsVerbatim', 0, async () => {
      const withLevel: string = '{"id":9,"title":"t","details":{"notification_level":0},"post_stream":{"posts":[{"id":1,"topic_id":9,"post_number":1,"cooked":"<p>1</p>"}]}}';
      const withoutLevel: string = '{"id":9,"title":"t","details":{"created_by":{"id":5}},"post_stream":{"posts":[{"id":1,"topic_id":9,"post_number":1,"cooked":"<p>1</p>"}]}}';
      const withDetails: NetworkResult<string> = {
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: withLevel
      };
      const noDetails: NetworkResult<string> = {
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: withoutLevel
      };

      const muted: NetworkResult<TopicDetail> =
        await new TopicService(new FakeBridge(withDetails)).getTopicDetail(9);
      expect(muted.success).assertTrue();
      expect(muted.data?.notificationLevel).assertEqual(0);

      const absent: NetworkResult<TopicDetail> =
        await new TopicService(new FakeBridge(noDetails)).getTopicDetail(9);
      expect(absent.success).assertTrue();
      expect(absent.data?.notificationLevel).assertUndefined();
    });

    // ===== 主题元数据(topics#update) =====
    //
    // PUT /t/{id}.json 的参数是**扁平**的 title / category_id / tags,不是 topic[...]——
    // 上游 topics_controller.rb#update 直接读 params[:category_id]。
    // 这条钉住拼装形态:写错嵌套层级时服务端会静默忽略字段(200 但什么都没改)。

    it('updatesTopicMetadataWithFlatParams', 0, async () => {
      const ok: NetworkResult<string> = {
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}'
      };
      const bridge: FakeBridge = new FakeBridge(ok);

      const result: NetworkResult<boolean> = await new TopicService(bridge)
        .updateTopicMetadata(123, { title: '新标题', categoryId: 4, tags: ['求助', 'linux'] });

      expect(result.success).assertTrue();
      expect(bridge.postedPath).assertEqual('/t/123.json');
      expect(bridge.postedBody).assertContain(`title=${encodeURIComponent('新标题')}`);
      expect(bridge.postedBody).assertContain('category_id=4');
      expect(bridge.postedBody).assertContain(`tags=${encodeURIComponent('求助,linux')}`);
      // 绝不能是 topic[...] 那种嵌套形态。
      expect(bridge.postedBody.indexOf('topic%5B') < 0).assertTrue();
    });

    // 只改分类时不能凭空带上 title / tags —— 服务端会把空 title 当成「改成空标题」。
    it('omitsFieldsThatWereNotProvided', 0, async () => {
      const ok: NetworkResult<string> = {
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}'
      };
      const bridge: FakeBridge = new FakeBridge(ok);

      await new TopicService(bridge).updateTopicMetadata(7, { categoryId: 12 });

      expect(bridge.postedBody).assertEqual('category_id=12');
    });

    // 一个字段都没有 = 调用方编程错误,本地拒发(不发请求)。
    it('refusesEmptyMetadataUpdateWithoutSending', 0, async () => {
      const ok: NetworkResult<string> = {
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}'
      };
      const bridge: FakeBridge = new FakeBridge(ok);

      const result: NetworkResult<boolean> = await new TopicService(bridge)
        .updateTopicMetadata(7, {});

      expect(result.success).assertFalse();
      expect(bridge.postedPath).assertEqual('');
      expect(result.error?.code).assertEqual(NetworkErrorCode.UNEXPECTED_RESPONSE);
    });

    // ===== 列表行「标为已读」(topics/bulk + dismiss_posts) =====
    //
    // 刻意不走 /topics/timings:那条会写 PostTiming(喂 CF 速率盾,本仓反复强调不能猛打),
    // 而 dismiss_posts 是纯 SQL 更新 topic_users.last_read_post_number。
    // body 是**手工预编码**的 %5B%5D(数组下标形态),不是 encodeURIComponent 的产物,
    // 所以这里逐字钉死:写成 topic_ids[]= 时服务端会把参数丢掉并静默什么都不改。
    it('marksTopicReadViaBulkDismissPosts', 0, async () => {
      const ok: NetworkResult<string> = {
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}'
      };
      const bridge: FakeBridge = new FakeBridge(ok);

      const result: NetworkResult<boolean> = await new TopicService(bridge).markTopicRead(1234);

      expect(result.success).assertTrue();
      expect(result.data).assertTrue();
      expect(bridge.postedPath).assertEqual('/topics/bulk');
      expect(bridge.postedBody).assertEqual('topic_ids%5B%5D=1234&operation%5Btype%5D=dismiss_posts');
    });

    // 没有主题 id 就没有可标记的东西:本地拒发(不发请求),按 LOCAL_ABORT 归类而非「网络问题」。
    it('refusesBulkDismissWithoutTopicId', 0, async () => {
      const ok: NetworkResult<string> = {
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}'
      };
      const bridge: FakeBridge = new FakeBridge(ok);

      const result: NetworkResult<boolean> = await new TopicService(bridge).markTopicRead(0);

      expect(result.success).assertFalse();
      expect(bridge.postedPath).assertEqual('');
      expect(result.error?.code).assertEqual(NetworkErrorCode.UNEXPECTED_RESPONSE);
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.LOCAL_ABORT);
    });

    // ===== 帖内搜索 / 只看某人 =====
    //
    // 帖内搜索用高级搜索语法 `topic:<id>` 限定范围,返回的 posts 自带 post_number(直接跳楼)。
    // 两条要钉住:q 的拼法(空格编码成 %20)、以及「别把邻近主题的命中带进来」——
    // 带进来点一下会跳到别的帖子的同名楼号,看起来像跳错楼。
    it('searchesWithinTopicAndDropsForeignHits', 0, async () => {
      const payload: string = JSON.stringify({
        posts: [
          {
            id: 11, topic_id: 123, post_number: 5, username: 'alice',
            blurb: '<span class="search-highlight">鸿蒙</span> 应用\n  分享'
          },
          { id: 12, topic_id: 999, post_number: 2, username: 'bob', blurb: '别的帖子' },
          { id: 13, topic_id: 123, post_number: 0, username: 'carol', blurb: '没有楼号' }
        ]
      });
      const bridge: FakeBridge = new FakeBridge({
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: payload
      });

      const result: NetworkResult<TopicPostHit[]> =
        await new TopicService(bridge).searchPostsInTopic(123, ' 鸿蒙 ');

      expect(result.success).assertTrue();
      expect(bridge.requestedPath).assertEqual(`/search.json?q=${encodeURIComponent('鸿蒙 topic:123')}`);
      expect(result.data?.length).assertEqual(1);
      expect(result.data?.[0].postNumber).assertEqual(5);
      expect(result.data?.[0].username).assertEqual('alice');
      // 摘要必须去标签、压平空白:结果行是单行两行截断,原样贴 HTML 会把 <span> 当正文显示。
      expect(result.data?.[0].excerpt.indexOf('<') < 0).assertTrue();
      expect(result.data?.[0].excerpt).assertContain('鸿蒙');
      expect(result.data?.[0].excerpt.indexOf('\n') < 0).assertTrue();
    });

    it('refusesEmptyTopicSearchWithoutSending', 0, async () => {
      const bridge: FakeBridge = new FakeBridge({
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}'
      });

      const result: NetworkResult<TopicPostHit[]> =
        await new TopicService(bridge).searchPostsInTopic(123, '   ');

      expect(result.success).assertFalse();
      expect(bridge.requestedPath).assertEqual('');
      expect(result.error?.failureKind).assertEqual(NetworkFailureKind.LOCAL_ABORT);
    });

    // 只看某人复用「版本公告取楼层」那套 username_filters(该站认这个参数),
    // 返回的 post_stream 已只剩此人的楼层,楼号仍是原始楼号,所以结果能直接跳楼。
    it('loadsPostsByUserViaUsernameFilters', 0, async () => {
      const payload: string = JSON.stringify({
        id: 123,
        title: '主题',
        post_stream: {
          posts: [
            { id: 1, post_number: 1, username: 'alice', cooked: '<p>楼主的话</p>' },
            { id: 9, post_number: 9, username: 'alice', cooked: '<p>再补一句</p>' }
          ]
        }
      });
      const bridge: FakeBridge = new FakeBridge({
        success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: payload
      });

      const result: NetworkResult<TopicPostHit[]> =
        await new TopicService(bridge).loadPostsByUser(123, ' alice ');

      expect(result.success).assertTrue();
      expect(bridge.requestedPath)
        .assertEqual('/t/123.json?username_filters=alice&include_suggested=false');
      expect(result.data?.length).assertEqual(2);
      expect(result.data?.[0].postNumber).assertEqual(1);
      expect(result.data?.[0].username).assertEqual('alice');
      expect(result.data?.[1].postNumber).assertEqual(9);
    });
  });
}
