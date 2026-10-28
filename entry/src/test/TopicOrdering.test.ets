import { describe, it, expect } from '@ohos/hypium';
import { Topic } from '../main/ets/models/Topic';
import { hasPinnedBlock, partitionPinnedFirst } from '../main/ets/services/topic/TopicOrdering';

function topicOf(id: number, pinned: boolean): Topic {
  const topic: Topic = new Topic();
  topic.id = id;
  topic.title = `t${id}`;
  topic.pinned = pinned;
  return topic;
}

function idsOf(topics: Topic[]): string {
  return topics.map((topic: Topic) => `${topic.id}`).join(',');
}

export default function topicOrderingTest() {
  describe('topicOrderingTest', () => {
    // 稳定分区:置顶块内部与普通块内部都保持服务端给的顺序(榜单顺序不能客户端重排)。
    it('putsPinnedFirstStably', 0, () => {
      const input: Topic[] = [topicOf(1, false), topicOf(2, true), topicOf(3, false), topicOf(4, true)];
      expect(idsOf(partitionPinnedFirst(input))).assertEqual('2,4,1,3');
    });

    it('keepsArrayUntouchedWhenNothingPinned', 0, () => {
      const input: Topic[] = [topicOf(1, false), topicOf(2, false)];
      expect(partitionPinnedFirst(input) === input).assertTrue();
      expect(hasPinnedBlock(input)).assertFalse();
    });

    it('keepsArrayUntouchedWhenEverythingPinned', 0, () => {
      const input: Topic[] = [topicOf(1, true), topicOf(2, true)];
      expect(partitionPinnedFirst(input) === input).assertTrue();
      expect(hasPinnedBlock(input)).assertTrue();
    });

    it('reportsPinnedBlockOnlyWhenFirstIsPinned', 0, () => {
      expect(hasPinnedBlock([])).assertFalse();
      expect(hasPinnedBlock([topicOf(1, false)])).assertFalse();
      expect(hasPinnedBlock(partitionPinnedFirst([topicOf(1, false), topicOf(2, true)]))).assertTrue();
    });

    // pinned 缺失(旧缓存/别的站点没这个字段)一律按普通帖处理,不能靠 undefined 真值判断。
    it('treatsMissingPinnedAsNormal', 0, () => {
      const topic: Topic = new Topic();
      topic.id = 9;
      expect(hasPinnedBlock([topic])).assertFalse();
    });
  });
}
