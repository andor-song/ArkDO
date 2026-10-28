import { describe, it, expect } from '@ohos/hypium';
import { TopicCategory, TopicTag } from '../main/ets/models/Topic';
import { FeedKey } from '../main/ets/services/site/FeedPrefs';
import {
  buildTopicListPath,
  createDefaultTopicListQuery,
  describeTopicListQuery,
  emptyStateForFeed,
  filterRequiresLogin,
  isDefaultTopicListQuery,
  sameTopicListQuery,
  topicListPrimaryTitle,
  topicListSummary,
  hasTopicListSummary,
  topicListSummaryLead,
  topicListSummaryTag,
  TopicListQuery
} from '../main/ets/services/topic/TopicListQuery';

const DEV: TopicCategory = { id: 98, name: '开发调优', color: '', textColor: '', slug: 'domestic' };
// slug 缺失的版块(站点元数据里偶有):退回纯 id 段。
const NO_SLUG: TopicCategory = { id: 7, name: '无 slug', color: '', textColor: '' };

// 有 id + slug 的标签走 slug/id 路由;只有名字的走按名字的路由。
const TAG_WITH_ID: TopicTag = { id: 1461, name: '三方客户端', slug: '1461-tag' };
const TAG_NAME_ONLY: TopicTag = { name: 'linux' };

function queryOf(filter: string, category?: TopicCategory, tag?: TopicTag): TopicListQuery {
  return { filter: filter, category: category, tag: tag };
}

function topQuery(period?: string, category?: TopicCategory, tag?: TopicTag): TopicListQuery {
  return { filter: FeedKey.TOP, category: category, tag: tag, topPeriod: period };
}

export default function topicListQueryTest() {
  describe('TopicListQuery', () => {

    // ===== 四种 scope × 过滤器 =====

    it('全站 scope 不带 /l/ 前缀', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.LATEST), 0)).assertEqual('/latest.json');
      expect(buildTopicListPath(queryOf(FeedKey.HOT), 0)).assertEqual('/hot.json');
      expect(buildTopicListPath(queryOf(FeedKey.UNREAD), 0)).assertEqual('/unread.json');
      expect(buildTopicListPath(queryOf(FeedKey.NEW), 0)).assertEqual('/new.json');
      expect(buildTopicListPath(queryOf(FeedKey.TOP), 0)).assertEqual('/top.json');
    });

    // 「最新发布」不是 Discourse 的 filter:走 latest 的路由 + order=created(按 created_at 倒序),
    // 否则 latest 排的是 bumped_at,老帖被回复就顶上来。四种 scope 都要挂上这个参数。
    it('最新发布 = latest 路由 + order=created', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.CREATED), 0)).assertEqual('/latest.json?order=created');
      expect(buildTopicListPath(queryOf(FeedKey.CREATED, DEV), 0))
        .assertEqual('/c/domestic/98/l/latest.json?order=created');
      expect(buildTopicListPath(queryOf(FeedKey.CREATED, undefined, TAG_WITH_ID), 0))
        .assertEqual('/tag/1461-tag/1461/l/latest.json?order=created');
      expect(buildTopicListPath(queryOf(FeedKey.CREATED, DEV, TAG_WITH_ID), 0))
        .assertEqual('/tags/c/domestic/98/1461-tag/1461/l/latest.json?order=created');
      // 路径里不该出现 'created.json' —— 那是个不存在的 filter,服务端会 404。
      expect(buildTopicListPath(queryOf(FeedKey.CREATED), 0).indexOf('created.json')).assertEqual(-1);
    });

    it('版块 scope 拼 /c/{slug}/{id}/l/{filter}', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.LATEST, DEV), 0))
        .assertEqual('/c/domestic/98/l/latest.json');
      // 改造前版块被写死成 latest,这条是本次要修的核心缺口。
      expect(buildTopicListPath(queryOf(FeedKey.UNREAD, DEV), 0))
        .assertEqual('/c/domestic/98/l/unread.json');
      expect(buildTopicListPath(queryOf(FeedKey.HOT, NO_SLUG), 0))
        .assertEqual('/c/7/l/hot.json');
    });

    it('标签 scope 优先用 slug/id,没有则按名字', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.LATEST, undefined, TAG_WITH_ID), 0))
        .assertEqual('/tag/1461-tag/1461/l/latest.json');
      expect(buildTopicListPath(queryOf(FeedKey.NEW, undefined, TAG_WITH_ID), 0))
        .assertEqual('/tag/1461-tag/1461/l/new.json');
      expect(buildTopicListPath(queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY), 0))
        .assertEqual('/tag/linux/l/latest.json');
    });

    it('版块 + 标签走 /tags/c/...', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.LATEST, DEV, TAG_WITH_ID), 0))
        .assertEqual('/tags/c/domestic/98/1461-tag/1461/l/latest.json');
      expect(buildTopicListPath(queryOf(FeedKey.UNREAD, DEV, TAG_WITH_ID), 0))
        .assertEqual('/tags/c/domestic/98/1461-tag/1461/l/unread.json');
    });

    it('非 ASCII 的标签名与版块 slug 会被 URL 编码', 0, () => {
      const path: string = buildTopicListPath(queryOf(FeedKey.LATEST, undefined, { name: '福利' }), 0);
      expect(path).assertEqual(`/tag/${encodeURIComponent('福利')}/l/latest.json`);
    });

    // ===== 分页 =====

    it('page>0 才带 page 参数', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.LATEST), 2)).assertEqual('/latest.json?page=2');
      expect(buildTopicListPath(queryOf(FeedKey.LATEST, DEV), 1))
        .assertEqual('/c/domestic/98/l/latest.json?page=1');
      expect(buildTopicListPath(queryOf(FeedKey.LATEST, DEV, TAG_WITH_ID), 3))
        .assertEqual('/tags/c/domestic/98/1461-tag/1461/l/latest.json?page=3');
    });

    // order 与 page 同时出现时只能有一个「?」,后面全用「&」接。
    it('最新发布的分页把 order 与 page 拼在同一个 query 串里', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.CREATED), 2))
        .assertEqual('/latest.json?order=created&page=2');
      expect(buildTopicListPath(queryOf(FeedKey.CREATED, DEV), 1))
        .assertEqual('/c/domestic/98/l/latest.json?order=created&page=1');
      const path: string = buildTopicListPath(queryOf(FeedKey.CREATED, DEV, TAG_WITH_ID), 3);
      expect(path).assertEqual('/tags/c/domestic/98/1461-tag/1461/l/latest.json?order=created&page=3');
      expect(path.indexOf('?')).assertEqual(path.lastIndexOf('?'));
    });

    // ===== 条件比较 / 默认判定 =====

    it('默认条件是全站 · 最新 · 无标签', 0, () => {
      expect(isDefaultTopicListQuery(createDefaultTopicListQuery())).assertTrue();
      expect(isDefaultTopicListQuery(queryOf(FeedKey.UNREAD))).assertFalse();
      expect(isDefaultTopicListQuery(queryOf(FeedKey.LATEST, DEV))).assertFalse();
      expect(isDefaultTopicListQuery(queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY))).assertFalse();
    });

    it('sameTopicListQuery 三个维度都比', 0, () => {
      expect(sameTopicListQuery(queryOf(FeedKey.LATEST, DEV), queryOf(FeedKey.LATEST, DEV))).assertTrue();
      expect(sameTopicListQuery(queryOf(FeedKey.LATEST, DEV), queryOf(FeedKey.UNREAD, DEV))).assertFalse();
      expect(sameTopicListQuery(queryOf(FeedKey.LATEST, DEV), queryOf(FeedKey.LATEST))).assertFalse();
      expect(sameTopicListQuery(
        queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY),
        queryOf(FeedKey.LATEST, undefined, TAG_WITH_ID))).assertFalse();
      // 标签按名字比:同一个标签一边有 id 一边只有名字,不能算成两个。
      expect(sameTopicListQuery(
        queryOf(FeedKey.LATEST, undefined, TAG_WITH_ID),
        queryOf(FeedKey.LATEST, undefined, { name: '三方客户端' }))).assertTrue();
    });

    it('unread / new 需要登录,latest / hot / top / created 不需要', 0, () => {
      expect(filterRequiresLogin(FeedKey.UNREAD)).assertTrue();
      expect(filterRequiresLogin(FeedKey.NEW)).assertTrue();
      expect(filterRequiresLogin(FeedKey.LATEST)).assertFalse();
      expect(filterRequiresLogin(FeedKey.HOT)).assertFalse();
      expect(filterRequiresLogin(FeedKey.TOP)).assertFalse();
      // created 是纯服务端排序,不看个人已读状态,匿名同样能拉。
      expect(filterRequiresLogin(FeedKey.CREATED)).assertFalse();
    });

    // ===== 排行榜时间范围(period) =====
    //
    // 上游 TopTopic.periods = daily/weekly/monthly/quarterly/yearly/all;不传 period 时用站点默认。
    // 这里钉住三件事:四种 scope 都带上、翻页时与 page 共存(不能拼出两个问号)、
    // 以及**别的 filter 绝不能带 period**(拼了服务端会忽略,但 URL 会显得它生效了)。
    it('排行榜带 period,且与四种 scope 组合', 0, () => {
      expect(buildTopicListPath(topQuery('weekly'), 0)).assertEqual('/top.json?period=weekly');
      expect(buildTopicListPath(topQuery('daily', DEV), 0))
        .assertEqual('/c/domestic/98/l/top.json?period=daily');
      expect(buildTopicListPath(topQuery('monthly', undefined, TAG_WITH_ID), 0))
        .assertEqual('/tag/1461-tag/1461/l/top.json?period=monthly');
      expect(buildTopicListPath(topQuery('all', DEV, TAG_WITH_ID), 0))
        .assertEqual('/tags/c/domestic/98/1461-tag/1461/l/top.json?period=all');
    });

    it('排行榜 period 与 page 共存,不重复问号', 0, () => {
      expect(buildTopicListPath(topQuery('yearly'), 2)).assertEqual('/top.json?period=yearly&page=2');
      // 没选档位时保持改动前的形态(服务端默认),别偷偷替用户做决定。
      expect(buildTopicListPath(topQuery(undefined), 0)).assertEqual('/top.json');
    });

    it('非排行榜 filter 忽略残留的 topPeriod', 0, () => {
      const stale: TopicListQuery = { filter: FeedKey.LATEST, topPeriod: 'weekly' };
      expect(buildTopicListPath(stale, 0)).assertEqual('/latest.json');
      expect(buildTopicListPath({ filter: FeedKey.CREATED, topPeriod: 'all' }, 0))
        .assertEqual('/latest.json?order=created');
    });

    // 时间范围也算「条件」:否则在抽屉里把本周切成全部时,isDirty 判 false,
    // 「查看结果」按钮会变成「关闭」,点了直接关面板、列表不重拉。
    it('时间范围参与等价判断与已选条件摘要', 0, () => {
      expect(sameTopicListQuery(topQuery('weekly'), topQuery('weekly'))).assertTrue();
      expect(sameTopicListQuery(topQuery('weekly'), topQuery('all'))).assertFalse();
      expect(sameTopicListQuery(topQuery(undefined), topQuery('weekly'))).assertFalse();
      expect(describeTopicListQuery(topQuery('weekly'))).assertEqual('排行榜 · 本周 · 全站');
      expect(describeTopicListQuery(topQuery('all', DEV))).assertEqual('排行榜 · 全部 · 开发调优');
      // 顶栏副行:换过排序且带 scope 时出现,时间范围跟在同一行里。
      // 版块不进副行——它是主标题(见 topicListPrimaryTitle),副行只有排序 + 标签。
      expect(topicListSummary(topQuery('daily', DEV))).assertEqual('排行榜 · 今日');
      // 标签只有在版块也选中时才进副行(否则它自己就是主标题)。
      expect(topicListSummary(topQuery('daily', undefined, TAG_WITH_ID))).assertEqual('排行榜 · 今日');
      expect(topicListSummary(topQuery('daily', DEV, TAG_WITH_ID)))
        .assertEqual('排行榜 · 今日 · 三方客户端');
      // 只选了排行榜(无 scope)时,排序名本身就是主标题,副行不重复写。
      expect(hasTopicListSummary(topQuery('daily'))).assertFalse();
    });

    // 只有残留 period、没有别的条件时,不能算「默认」——抽屉会因此显示「重置」。
    // (CategoryDrawer.setFilter 离开排行榜时会清掉它,这里是防御性断言。)
    it('残留 period 不算默认条件', 0, () => {
      expect(isDefaultTopicListQuery({ filter: FeedKey.LATEST, topPeriod: 'weekly' })).assertFalse();
      expect(isDefaultTopicListQuery(createDefaultTopicListQuery())).assertTrue();
    });

    // ===== 顶栏文案 =====

    it('主标题按 版块 → 标签 → 过滤器 取,全默认时回空串', 0, () => {
      expect(topicListPrimaryTitle(createDefaultTopicListQuery())).assertEqual('');
      expect(topicListPrimaryTitle(queryOf(FeedKey.UNREAD))).assertEqual('未读');
      expect(topicListPrimaryTitle(queryOf(FeedKey.CREATED))).assertEqual('最新发布');
      // /new.json 回的是「未读 + 从没打开过」的合集,按 bumped_at 排,叫「新主题」名实不符。
      expect(topicListPrimaryTitle(queryOf(FeedKey.NEW))).assertEqual('未读新帖');
      expect(topicListPrimaryTitle(queryOf(FeedKey.LATEST, DEV))).assertEqual('开发调优');
      // 顶栏会在名字前面画标签图标,所以标题本身不带 # 之类的前缀修饰。
      expect(topicListPrimaryTitle(queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY))).assertEqual('linux');
      // 版块优先于标签。
      expect(topicListPrimaryTitle(queryOf(FeedKey.LATEST, DEV, TAG_NAME_ONLY))).assertEqual('开发调优');
    });

    it('副行一旦出现就把排序名写全,包括默认的「最新」', 0, () => {
      expect(topicListSummaryLead(createDefaultTopicListQuery())).assertEqual('');
      // 只选了个版块/标签:副行不出现(标题独占一行),排序名也就无处可写。
      expect(topicListSummaryLead(queryOf(FeedKey.LATEST, DEV))).assertEqual('');
      expect(topicListSummaryLead(queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY))).assertEqual('');
      // 没有 scope 时排序名本身就是主标题,副行再写一遍就重复了。
      expect(topicListSummaryLead(queryOf(FeedKey.UNREAD))).assertEqual('');
      expect(topicListPrimaryTitle(queryOf(FeedKey.UNREAD))).assertEqual('未读');
      // 有 scope + 换过排序。
      expect(topicListSummaryLead(queryOf(FeedKey.UNREAD, DEV))).assertEqual('未读');
      expect(topicListSummaryLead(queryOf(FeedKey.HOT, undefined, TAG_NAME_ONLY))).assertEqual('热门');
      // 版块 + 标签:副行本来就要为标签开,「最新」顺手补全,免得这行太空。
      expect(topicListSummaryLead(queryOf(FeedKey.LATEST, DEV, TAG_NAME_ONLY))).assertEqual('最新');
      expect(topicListSummary(queryOf(FeedKey.LATEST, DEV, TAG_NAME_ONLY))).assertEqual('最新 · linux');
    });

    it('没东西可说时不长副行,主标题独占一行', 0, () => {
      expect(hasTopicListSummary(createDefaultTopicListQuery())).assertFalse();
      expect(hasTopicListSummary(queryOf(FeedKey.LATEST, DEV))).assertFalse();
      expect(hasTopicListSummary(queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY))).assertFalse();
      // 主标题已经是「未读」了,不该再长一行副行出来重复它。
      expect(hasTopicListSummary(queryOf(FeedKey.UNREAD))).assertFalse();
      expect(hasTopicListSummary(queryOf(FeedKey.UNREAD, DEV))).assertTrue();
      // 版块 + 标签:标签挤不进主标题,即便排序是默认的也得长副行。
      expect(hasTopicListSummary(queryOf(FeedKey.LATEST, DEV, TAG_NAME_ONLY))).assertTrue();
    });

    it('只有「版块 + 标签」都选了时,标签才挂到副行(否则它就是主标题)', 0, () => {
      expect(topicListSummaryTag(queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY))).assertUndefined();
      expect(topicListSummaryTag(queryOf(FeedKey.LATEST, DEV))).assertUndefined();
      const carried: TopicTag | undefined = topicListSummaryTag(queryOf(FeedKey.HOT, DEV, TAG_NAME_ONLY));
      expect(carried !== undefined).assertTrue();
      expect((carried as TopicTag).name).assertEqual('linux');
      expect(topicListSummary(queryOf(FeedKey.HOT, DEV, TAG_NAME_ONLY))).assertEqual('热门 · linux');
    });

    it('抽屉确认区的描述一项都不省,无 scope 时写明「全站」', 0, () => {
      expect(describeTopicListQuery(createDefaultTopicListQuery())).assertEqual('最新 · 全站');
      expect(describeTopicListQuery(queryOf(FeedKey.UNREAD))).assertEqual('未读 · 全站');
      expect(describeTopicListQuery(queryOf(FeedKey.UNREAD, DEV))).assertEqual('未读 · 开发调优');
      // 有标签时标签就是 scope,不再补「全站」。
      expect(describeTopicListQuery(queryOf(FeedKey.LATEST, undefined, TAG_NAME_ONLY)))
        .assertEqual('最新 · linux');
      expect(describeTopicListQuery(queryOf(FeedKey.LATEST, DEV, TAG_NAME_ONLY)))
        .assertEqual('最新 · 开发调优 · linux');
    });

    // ===== 已读：与其它 filter 同类，可组合 =====
    //
    // `read` 在 Discourse core 的 `Discourse.filters` 列表里（lib/discourse.rb），
    // routes.rb 用 `Discourse.filters.each` 同时生成 `/read.json`、`/c/.../l/read.json`、
    // `/tag/.../l/read.json`，`create_list(:read)` 也走 `default_results`（含版块/标签过滤）。
    // 早先误判成「用户活动端点、不可组合」并加过置灰，核对上游后已纠正。

    it('已读走全站路径，分页规则与其它 feed 一致', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.READ), 0)).assertEqual('/read.json');
      expect(buildTopicListPath(queryOf(FeedKey.READ), 2)).assertEqual('/read.json?page=2');
    });

    // 版块/标签下必须拼 /l/read.json —— 与 unread/hot 等完全同形。
    // 这几条同时守住「有人再把 read 当特例」：一旦回退全站，立刻红。
    it('已读与版块/标签组合时照常拼 /l/read.json', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.READ, DEV), 0))
        .assertEqual('/c/domestic/98/l/read.json');
      expect(buildTopicListPath(queryOf(FeedKey.READ, undefined, TAG_WITH_ID), 0))
        .assertEqual('/tag/1461-tag/1461/l/read.json');
      expect(buildTopicListPath(queryOf(FeedKey.READ, DEV, TAG_WITH_ID), 0))
        .assertEqual('/tags/c/domestic/98/1461-tag/1461/l/read.json');
    });

    // 交叉点：带 scope 且分页 >0。丢弃 scope 与拼 query 串两段逻辑在这里共同作用。
    it('已读 + 版块 + 分页：scope 与 page 同时生效', 0, () => {
      expect(buildTopicListPath(queryOf(FeedKey.READ, DEV), 2))
        .assertEqual('/c/domestic/98/l/read.json?page=2');
    });

    it('已读需要登录，与未读/未读新帖一致', 0, () => {
      expect(filterRequiresLogin(FeedKey.READ)).assertTrue();
      expect(filterRequiresLogin(FeedKey.UNREAD)).assertTrue();
      expect(filterRequiresLogin(FeedKey.NEW)).assertTrue();
      // 其余三类匿名可看。
      expect(filterRequiresLogin(FeedKey.LATEST)).assertFalse();
      expect(filterRequiresLogin(FeedKey.HOT)).assertFalse();
      expect(filterRequiresLogin(FeedKey.TOP)).assertFalse();
      expect(filterRequiresLogin(FeedKey.CREATED)).assertFalse();
    });

    // ===== 空态文案 =====

    // 原先所有 feed 共用「暂无帖子数据」：在未读筛选下这句等于没说 ——
    // 用户要知道的是「读完了」还是「一条未读都没有」。
    it('未读与已读各有专属空态，其余保持通用文案', 0, () => {
      expect(emptyStateForFeed(FeedKey.UNREAD).title).assertEqual('没有未读帖子了');
      expect(emptyStateForFeed(FeedKey.NEW).title).assertEqual('没有未读新帖了');
      expect(emptyStateForFeed(FeedKey.READ).title).assertEqual('还没有读过的帖子');
      expect(emptyStateForFeed(FeedKey.LATEST).title).assertEqual('暂无帖子数据');
      // 通用档不编副标题（「最新为空」本身是异常态，多说一句反而像在解释）。
      expect(emptyStateForFeed(FeedKey.LATEST).subtitle).assertEqual('');
    });

    it('特化档都带副标题，说明这个列表什么时候会有内容', 0, () => {
      expect(emptyStateForFeed(FeedKey.UNREAD).subtitle.length > 0).assertTrue();
      expect(emptyStateForFeed(FeedKey.NEW).subtitle.length > 0).assertTrue();
      expect(emptyStateForFeed(FeedKey.READ).subtitle.length > 0).assertTrue();
    });
  });
}
