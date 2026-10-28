import { describe, it, expect } from '@ohos/hypium';
import { buildTopicShareText, buildTopicUrl } from '../main/ets/services/topic/TopicLink';

export default function topicLinkTest() {
  describe('topicLinkTest', () => {
    it('usesSlugWhenPresent', 0, () => {
      expect(buildTopicUrl('https://linux.do', 'my-topic', 42))
        .assertEqual('https://linux.do/t/my-topic/42');
    });

    // 搜索结果 / 推送载荷常常只有 id，没有 slug —— 退回 /t/topic/{id}，与站内其余拼链接处同形态。
    it('fallsBackToIdOnlyWithoutSlug', 0, () => {
      expect(buildTopicUrl('https://linux.do', undefined, 42)).assertEqual('https://linux.do/t/topic/42');
      expect(buildTopicUrl('https://linux.do', '', 42)).assertEqual('https://linux.do/t/topic/42');
      expect(buildTopicUrl('https://linux.do', '   ', 42)).assertEqual('https://linux.do/t/topic/42');
    });

    // 站点地址尾部带斜杠时不能拼出 //t/…
    it('normalizesTrailingSlash', 0, () => {
      expect(buildTopicUrl('https://linux.do/', 's', 7)).assertEqual('https://linux.do/t/s/7');
    });

    // 站点未配置 / id 非法时返回空串，调用方据此不显示「复制链接」。
    it('returnsEmptyForInvalidInput', 0, () => {
      expect(buildTopicUrl('', 's', 7)).assertEqual('');
      expect(buildTopicUrl('https://linux.do', 's', 0)).assertEqual('');
    });

    // 分享文本：标题 + 空行 + 链接（与详情页 sharePost 的三段式同构，列表行没有正文）。
    it('joinsTitleAndUrlForShareText', 0, () => {
      expect(buildTopicShareText('鸿蒙应用分享', 'https://linux.do/t/topic/42'))
        .assertEqual('鸿蒙应用分享\n\nhttps://linux.do/t/topic/42');
    });

    // 单边缺失时不能留下空行或空串：链接没了就只剩标题（调用方据此仍可复制文本），
    // 标题没了就只剩链接（服务端偶尔回空标题的自动化主题）。
    it('degradesWhenEitherSideMissing', 0, () => {
      expect(buildTopicShareText('只有标题', '')).assertEqual('只有标题');
      expect(buildTopicShareText('  ', 'https://linux.do/t/1')).assertEqual('https://linux.do/t/1');
      expect(buildTopicShareText('', '')).assertEqual('');
    });
  });
}
