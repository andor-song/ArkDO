import { Topic } from '../../models/Topic';

/**
 * 列表排序的纯函数(本地 harness 可跑)。
 *
 * 为什么需要它:Discourse 的列表接口**通常**已经把置顶帖排在最前,但那是「通常」——
 * 分类列表里置顶的是本版块的、全站列表里置顶的是全局的,分页混排、缓存拼页之后
 * 客户端收到的顺序不保证。界面上「置顶」是分区的语义(最前一块),顺序错一行就会
 * 让置顶帖夹在普通帖中间,比没有分区更难看。
 *
 * 因此这里只做**稳定**分区:置顶在前、其余保持服务端给的相对顺序。稳定很关键 ——
 * 置顶块内部仍按服务端的榜单顺序排,不能被我们按 id 或时间重排。
 */

function isPinned(topic: Topic): boolean {
  return topic.pinned === true;
}

/** 置顶在前、其余保持原相对顺序。没有置顶时原样返回同一个数组(不制造无谓的拷贝)。 */
export function partitionPinnedFirst(topics: Topic[]): Topic[] {
  let pinnedCount: number = 0;
  for (let index: number = 0; index < topics.length; index++) {
    if (isPinned(topics[index])) {
      pinnedCount++;
    }
  }
  if (pinnedCount === 0 || pinnedCount === topics.length) {
    return topics;
  }
  const pinned: Topic[] = [];
  const rest: Topic[] = [];
  for (let index: number = 0; index < topics.length; index++) {
    if (isPinned(topics[index])) {
      pinned.push(topics[index]);
    } else {
      rest.push(topics[index]);
    }
  }
  return pinned.concat(rest);
}

/**
 * 第一块是不是置顶块。列表渲染据此决定要不要画「置顶」分区标题 ——
 * 判据只看第一条:partitionPinnedFirst 之后置顶块必然从 0 开始。
 */
export function hasPinnedBlock(topics: Topic[]): boolean {
  return topics.length > 0 && isPinned(topics[0]);
}
