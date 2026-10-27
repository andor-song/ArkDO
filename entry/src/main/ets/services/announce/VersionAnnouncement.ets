import { Log } from '../logging/Log';
import { JsonNetworkClient, NetworkResult } from '../network/NetworkTypes';

// 诊断关键字:hilog / DevEco Log 里搜 ANNOUNCE_DIAG 即可看到公告全链路日志。
const LOG_TAG: string = '[ArkDO][ANNOUNCE_DIAG]';

// 版本公告帖:你能一直回复的那个帖。每个版本在此帖发一条回复,开头写 [v<versionCode>],
// 应用启动时用当前 versionCode 匹配对应那条弹出。换帖只改这里。
export const ANNOUNCE_TOPIC_ID: number = 2590051;
// 只取你本人的回复(帖子里别人插楼不干扰),对应 URL 的 username_filters。
const ANNOUNCE_USERNAME: string = 'joeyyin';
// 从帖尾往前最多「补拉」多少条未加载的楼找匹配。首屏已返回的楼(前 20,多为较旧的版本公告)
// 会先被免费扫一遍;这个上限只约束帖尾那些要单独补拉的新楼,避免帖子很大时发太多请求。
const MAX_TAIL_FETCH: number = 15;
// 补拉走**批量**端点:一次把尾部这些楼全带上(`post_ids[]=a&post_ids[]=b&…`)。
//
// 原先是一楼一发(逐个 await),冷启动时 5 秒内连打 15 个 `posts.json` —— 实测直接撞上
// Cloudflare 的 429 挑战页,把整个首页拖进过盾流程(2026-10-27 真机日志)。而同一个
// `posts.json` 端点本来就接受多个 post_ids[],批量拿回一次就够:请求数 15 → 1。
//
// 批大小的上限与 MAX_TAIL_FETCH 一致即可;真要调大,注意 URL 长度(15 个 id ≈ 15×20 字符,
// 离常见 8KB 上限还很远,但别无限涨)。
const FETCH_BATCH_SIZE: number = MAX_TAIL_FETCH;
// 版本标记正则:[v900008]。Discourse 里这写法无匹配引用,会原样留在 cooked 中,
// 哪怕被 **加粗** 包成 <strong>[v900008]</strong>,子串仍在,照样命中。
const MARKER_PATTERN: RegExp = new RegExp('\\[v(\\d+)\\]', 'g');

// —— Discourse 原始响应里我们用到的字段(其余忽略)——
interface RawPost {
  id: number;
  cooked?: string;
  post_number?: number;
}

interface RawPostStream {
  posts?: RawPost[];
  // 该帖(经 username_filters 过滤后)全部楼层 id 的完整有序列表,不分页——
  // 这是"从后往匹配"的依据:posts 默认只含前 20 楼,最新的公告要靠 stream 末尾的 id 单独补拉。
  stream?: number[];
}

interface RawTopic {
  post_stream?: RawPostStream;
}

export interface VersionAnnouncement {
  // 跳楼要用:公告帖 id + 楼号。
  topicId: number;
  postNumber: number;
  // 该楼 [vXXXX] 标记里声明的版本号。
  versionCode: number;
  // 完整正文 HTML(含 [vXXXX] 标记,不剥离),直接喂 PostRichContent。
  cookedHtml: string;
}

export interface AnnouncementScanResult {
  // 命中当前 versionCode 的那条公告(没有则 null)。
  current: VersionAnnouncement | null;
  // 版本号高于当前 versionCode 的公告里最高的那条——即"有新版可升级"(没有则 null)。
  newer: VersionAnnouncement | null;
}

// 扫描版本公告帖。任何失败/找不到都返回空结果(即不弹窗),不抛错。
export class VersionAnnouncementService {
  private bridge: JsonNetworkClient;

  constructor(bridge: JsonNetworkClient) {
    this.bridge = bridge;
  }

  // 一趟扫描同时产出「当前版本公告」和「更高版本公告」:
  // 从 stream 末尾(最新)往前走,途中遇到比当前版本高的记为 newer(取最高),
  // 一撞上当前版本那楼就停——它上面不可能再有更高版本了,补拉次数因此约等于"比你新的版本数"。
  async scan(versionCode: number): Promise<AnnouncementScanResult> {
    const empty: AnnouncementScanResult = { current: null, newer: null };
    try {
      const path: string = `/t/${ANNOUNCE_TOPIC_ID}.json?username_filters=${ANNOUNCE_USERNAME}`;
      Log.i(`${LOG_TAG} 开始扫公告 versionCode=${versionCode} 目标标记=[v${versionCode}] path=${path}`);
      const res: NetworkResult<string> = await this.bridge.getJson(path);
      Log.i(`${LOG_TAG} 响应 success=${res.success} status=${res.statusCode} challenge=${res.challengeState} 体长度=${res.data ? res.data.length : 0}`);
      if (!res.success || res.data === undefined) {
        Log.w(`${LOG_TAG} 拉公告帖失败 status=${res.statusCode}`);
        return empty;
      }

      const topic: RawTopic = JSON.parse(res.data) as RawTopic;
      const stream: number[] = topic.post_stream?.stream ?? [];
      const loaded: RawPost[] = topic.post_stream?.posts ?? [];
      Log.i(`${LOG_TAG} stream 楼层数=${stream.length} 首屏已加载楼=${loaded.length} stream=${JSON.stringify(stream)}`);
      if (stream.length === 0) {
        Log.w(`${LOG_TAG} stream 为空——可能 username_filters 没匹配到你的回复,或响应结构异常`);
        return empty;
      }

      // 首屏已返回的楼建索引:扫到它们时是免费的,不占补拉配额。
      const loadedById: Map<number, RawPost> = new Map();
      for (let i: number = 0; i < loaded.length; i++) {
        loadedById.set(loaded[i].id, loaded[i]);
      }

      // 先把「要补拉的尾部楼」挑出来,一次批量取回;之后整趟扫描就只在本地 Map 上走,
      // 不再边扫边发请求。顺序保持「从帖尾往前」,因为命中当前版本时要立刻停。
      const tailIds: number[] = [];
      for (let i: number = stream.length - 1; i >= 0 && tailIds.length < FETCH_BATCH_SIZE; i--) {
        const id: number = stream[i];
        if (!loadedById.has(id)) {
          tailIds.push(id);
        }
      }
      let fetched: number = 0;
      if (tailIds.length > 0) {
        const tailPosts: RawPost[] = await this.fetchPostsByIds(tailIds);
        fetched = tailIds.length;
        for (let i: number = 0; i < tailPosts.length; i++) {
          loadedById.set(tailPosts[i].id, tailPosts[i]);
        }
        Log.i(`${LOG_TAG} 批量补拉 tailIds=${tailIds.length} 取回=${tailPosts.length}`);
      }

      let current: VersionAnnouncement | null = null;
      let newer: VersionAnnouncement | null = null;
      for (let i: number = stream.length - 1; i >= 0; i--) {
        const id: number = stream[i];
        const post: RawPost | undefined = loadedById.get(id);
        if (!post) {
          continue;
        }

        const marked: VersionAnnouncement | null = this.readAnnouncement(post, '已加载');
        if (!marked) {
          continue;
        }
        if (marked.versionCode === versionCode) {
          current = marked;
          Log.i(`${LOG_TAG} 命中当前版本:楼号=${marked.postNumber} 正文长度=${marked.cookedHtml.length},停止向前扫`);
          break;
        }
        if (marked.versionCode > versionCode && (newer === null || marked.versionCode > newer.versionCode)) {
          newer = marked;
          Log.i(`${LOG_TAG} 发现更高版本 v${marked.versionCode} 楼号=${marked.postNumber}`);
        }
      }

      if (current === null) {
        Log.w(`${LOG_TAG} 未找到 [v${versionCode}] 对应的公告(补拉 ${fetched} 楼)`);
      }
      return { current: current, newer: newer };
    } catch (error) {
      Log.e(`${LOG_TAG} 扫公告异常: ${JSON.stringify(error)}`);
      return empty;
    }
  }

  // 批量补拉 stream 末尾那些不在首屏里的楼。**一次请求**取回全部:
  // 同一个 posts.json 端点接受多个 post_ids[],没必要一楼一发(那样冷启动时会连撞 CF 限流)。
  //
  // 拿不到就返回空数组:公告扫描是「有就弹、没有就算了」的锦上添花功能,
  // 任何失败都不该影响首页加载,也不该抛出到外层。
  private async fetchPostsByIds(ids: number[]): Promise<RawPost[]> {
    const params: string[] = [];
    for (let i: number = 0; i < ids.length; i++) {
      params.push(`post_ids%5B%5D=${ids[i]}`);
    }
    const path: string = `/t/${ANNOUNCE_TOPIC_ID}/posts.json?${params.join('&')}&include_suggested=false`;
    const res: NetworkResult<string> = await this.bridge.getJson(path);
    if (!res.success || res.data === undefined) {
      Log.w(`${LOG_TAG} 批量补拉失败 status=${res.statusCode} 请求数=${ids.length}`);
      return [];
    }
    try {
      const parsed: RawTopic = JSON.parse(res.data) as RawTopic;
      return parsed.post_stream?.posts ?? [];
    } catch (error) {
      Log.w(`${LOG_TAG} 批量补拉响应不是有效 JSON,本轮跳过`);
      return [];
    }
  }

  // 单楼解析:带 [vXXXX] 标记则返回可展示的公告,否则返回 null。source 仅用于日志。
  private readAnnouncement(post: RawPost, source: string): VersionAnnouncement | null {
    // 主帖(楼层1)是总更新日志,正文里罗列各版本号纯文本,不是某一版的公告——
    // 不跳过的话会被误判成"有新版本"。
    if (post.post_number === 1) {
      return null;
    }
    const cooked: string = post.cooked ?? '';
    const marked: number = this.readMarkerVersion(cooked);
    Log.i(`${LOG_TAG} 扫 id=${post.id} 楼号=${post.post_number ?? -1} 来源=${source} 标记版本=${marked} cooked前120=${cooked.substring(0, 120)}`);
    if (marked <= 0 || cooked.trim().length === 0) {
      return null;
    }
    return {
      topicId: ANNOUNCE_TOPIC_ID,
      postNumber: post.post_number ?? 0,
      versionCode: marked,
      cookedHtml: cooked
    };
  }

  // 取该楼声明的版本号;一楼写了多个标记(如回顾旧版)时取最大的那个。无标记返回 0。
  private readMarkerVersion(cooked: string): number {
    let best: number = 0;
    // 全局正则带 lastIndex 状态,复用同一个实例前必须归零,否则下一楼会从上次位置续扫。
    MARKER_PATTERN.lastIndex = 0;
    let match: RegExpExecArray | null = MARKER_PATTERN.exec(cooked);
    while (match !== null) {
      const parsed: number = Number.parseInt(match[1], 10);
      if (!Number.isNaN(parsed) && parsed > best) {
        best = parsed;
      }
      match = MARKER_PATTERN.exec(cooked);
    }
    return best;
  }
}
