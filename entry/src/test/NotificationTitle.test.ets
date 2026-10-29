import { describe, it, expect, beforeAll, afterAll } from '@ohos/hypium';
import { SiteFixture } from './SiteFixture';
import { NotificationApi } from '../main/ets/services/notification/NotificationApi';
import { NotificationItem } from '../main/ets/models/Notification';
import {
  ChallengeState,
  JsonNetworkClient,
  NetworkResult
} from '../main/ets/services/network/NetworkTypes';

// 只喂一份 /notifications.json 的响应体,不需要别的动作。
class PayloadBridge implements JsonNetworkClient {
  private payload: string;

  constructor(payload: string) {
    this.payload = payload;
  }

  getJson(path: string): Promise<NetworkResult<string>> {
    return Promise.resolve({
      success: true,
      statusCode: 200,
      challengeState: ChallengeState.NONE,
      data: this.payload
    });
  }

  postForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve({ success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}' });
  }

  postJson(path: string, body: string): Promise<NetworkResult<string>> {
    return this.postForm(path, body);
  }

  putJson(path: string): Promise<NetworkResult<string>> {
    return Promise.resolve({ success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}' });
  }

  putForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve({ success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}' });
  }

  deleteForm(path: string, body: string): Promise<NetworkResult<string>> {
    return Promise.resolve({ success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}' });
  }

  uploadImage(base64: string, fileName: string, mimeType: string): Promise<NetworkResult<string>> {
    return Promise.resolve({ success: true, statusCode: 200, challengeState: ChallengeState.NONE, data: '{}' });
  }
}

// 通知标题的实体解码。对应真机现象:同一个帖 2496114,从列表进标题是「any状态&综合讨论集中贴」,
// 从通知进成了「any状态&amp;综合讨论集中贴」——上游 NotificationSerializer 给的是 fancy_title
// (CGI.escapeHTML 过的那份),当纯文本直接显示就会露出实体。
export default function notificationTitleTest() {
  describe('notificationTitleTest', () => {
    beforeAll(() => SiteFixture.pinLinuxDo());

    afterAll(() => SiteFixture.restore());

    it('decodesHtmlEntitiesInFancyTitle', 0, async () => {
      const payload: string = '{"notifications":[{"id":1,"notification_type":2,' +
        '"fancy_title":"any状态&amp;综合讨论集中贴","topic_id":2496114,"post_number":26081,' +
        '"read":false,"created_at":"2026-10-28T12:46:54.000Z","data":{}}]}';
      const result: NetworkResult<NotificationItem[]> =
        await new NotificationApi(new PayloadBridge(payload)).load(30, 0, true);

      expect(result.success).assertTrue();
      expect(result.data?.length).assertEqual(1);
      expect(result.data?.[0].title).assertEqual('any状态&综合讨论集中贴');
    });

    it('leavesPlainTitleUntouched', 0, async () => {
      // 没有实体就不该动:标题里的 & < > 是用户真写的字。
      const payload: string = '{"notifications":[{"id":2,"notification_type":2,' +
        '"fancy_title":"a & b <c>","topic_id":1,"post_number":1,' +
        '"read":false,"created_at":"2026-10-28T12:46:54.000Z","data":{}}]}';
      const result: NetworkResult<NotificationItem[]> =
        await new NotificationApi(new PayloadBridge(payload)).load(30, 0, true);

      expect(result.data?.[0].title).assertEqual('a & b <c>');
    });
  });
}
