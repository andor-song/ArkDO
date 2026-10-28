import { Log } from '../logging/Log';
import { TopicTag } from '../../models/Topic';

const LOG_TAG: string = '[ArkDO][TopicMetaBus]';

/**
 * 详情页改完主题标题/分类/标签后，通知还在栈下的列表页就地更新那一行。
 *
 * 为什么需要它：列表行读的是**列表接口**那份 `Topic`（`title` / `categoryId` / `tags`），
 * 详情页改的是服务端与详情对象；返回列表时不会重新拉取，于是标题还显示旧的 ——
 * 用户会以为没保存成功。与 `TopicReadStateEventBus` 同一套机制（静态监听表 + 退订闭包）。
 */
export interface TopicMetadataChanged {
  topicId: number;
  title: string;
  // 分类 id。undefined = 本次没改分类（调用方不要动本地值）。
  categoryId?: number;
  // 标签。undefined = 本次没改标签。
  tags?: TopicTag[];
}

export class TopicMetadataEventBus {
  private static listeners: Map<number, (event: TopicMetadataChanged) => void> = new Map();
  private static sequence: number = 0;

  static subscribe(listener: (event: TopicMetadataChanged) => void): () => void {
    TopicMetadataEventBus.sequence++;
    const id: number = TopicMetadataEventBus.sequence;
    TopicMetadataEventBus.listeners.set(id, listener);
    return (): void => {
      TopicMetadataEventBus.listeners.delete(id);
    };
  }

  static publish(event: TopicMetadataChanged): void {
    TopicMetadataEventBus.listeners.forEach((listener: (event: TopicMetadataChanged) => void) => {
      try {
        listener(event);
      } catch (error) {
        // 单个订阅者异常不能拖垮其它页面（与 TopicReadStateEventBus 同规矩）。
        Log.i(`${LOG_TAG} listener failed error=${JSON.stringify(error)}`);
      }
    });
  }

  // 仅供测试复位。
  static resetForTest(): void {
    TopicMetadataEventBus.listeners.clear();
    TopicMetadataEventBus.sequence = 0;
  }
}
