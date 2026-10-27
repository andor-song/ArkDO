import { describe, it, expect } from '@ohos/hypium';
import { TopicCategory } from '../main/ets/models/Topic';
import { CategorySearchHit, searchCategories } from '../main/ets/services/site/CategorySearch';

function category(id: number, name: string, parentId?: number): TopicCategory {
  const item: TopicCategory = { id: id, name: name, color: '', textColor: '' };
  if (parentId !== undefined) {
    item.parentCategoryId = parentId;
  }
  return item;
}

// 三个顶级 + 两个子版块（「其他」重名，用来钉住「必须带父版块」这一点）。
const TREE: TopicCategory[] = [
  category(1, '开发调优'),
  category(2, '问与答'),
  category(3, '闲聊'),
  category(11, '其他', 1),
  category(21, '其他', 2)
];

// 专门给「顶级排在子版块前」用的树：查询词同时命中顶级与两个子版块。
const MIXED: TopicCategory[] = [
  category(1, '开发调优'),
  category(2, '问与答'),
  category(31, '其他分类'),
  category(11, '其他', 1),
  category(21, '其他', 2)
];

export default function categorySearchTest() {
  describe('categorySearchTest', () => {
    it('emptyQueryReturnsNothing', 0, () => {
      // 空查询返回空数组：调用方据此回退到常规树，而不是显示一个「全部」的搜索结果。
      expect(searchCategories(TREE, '').length).assertEqual(0);
      expect(searchCategories(TREE, '   ').length).assertEqual(0);
    });

    it('matchesSubstringOfName', 0, () => {
      const hits: CategorySearchHit[] = searchCategories(TREE, '调优');
      expect(hits.length).assertEqual(1);
      expect(hits[0].category.id).assertEqual(1);
      expect(hits[0].isChild).assertFalse();
    });

    // 只命中子版块时也要能搜到：搜「问」同时命中顶级「问与答」和子版块「其他」的父版块名吗？
    // 不 —— 子版块按**自己的名字**匹配，父版块名不参与。这条钉的是「按自身名匹配」。
    it('matchesChildByItsOwnNameOnly', 0, () => {
      const hits: CategorySearchHit[] = searchCategories(TREE, '其他');
      expect(hits.length).assertEqual(2);
      // 两个「其他」分属不同父版块 —— 结果必须能分辨，否则用户不知道该选哪个。
      expect(hits[0].parent.id).assertEqual(1);
      expect(hits[1].parent.id).assertEqual(2);
      expect(hits[0].isChild).assertTrue();
      expect(hits[1].isChild).assertTrue();
      // 分辨靠的是面包屑（UI 渲染它），不是靠 parent 字段躺在数据结构里。
      expect(hits[0].breadcrumb).assertEqual('开发调优');
      expect(hits[1].breadcrumb).assertEqual('问与答');
    });

    // 顶级命中排在子版块命中的前面：从粗到细。
    // 用同时命中两侧的查询（「其他」既命中两个子版块，也命中顶级「其他分类」）。
    it('topLevelHitsComeBeforeChildHits', 0, () => {
      const mixed: CategorySearchHit[] = searchCategories(MIXED, '其他');
      expect(mixed.length).assertEqual(3);
      // 顶级「其他分类」必须排在两个子版块「其他」前面。
      expect(mixed[0].isChild).assertFalse();
      expect(mixed[0].category.name).assertEqual('其他分类');
      expect(mixed[1].isChild).assertTrue();
      expect(mixed[2].isChild).assertTrue();
    });

    it('caseInsensitiveForAscii', 0, () => {
      const tree: TopicCategory[] = [category(9, 'DevOps')];
      expect(searchCategories(tree, 'devops').length).assertEqual(1);
      expect(searchCategories(tree, 'DEVOPS').length).assertEqual(1);
    });

    // 顶级版块的 parent 必须是**自身**（CategoryRow 的图标兜底约定）；给 undefined 会崩。
    it('topLevelHitCarriesItselfAsParent', 0, () => {
      const hits: CategorySearchHit[] = searchCategories(TREE, '开发');
      expect(hits[0].parent.id).assertEqual(1);
      expect(hits[0].parent.name).assertEqual('开发调优');
    });

    it('noMatchReturnsEmpty', 0, () => {
      expect(searchCategories(TREE, '不存在的版块').length).assertEqual(0);
    });

    // 父版块不存在的「孤儿」版块必须仍然可搜到。
    // 只按 parentCategoryId 分组会把它塞进一个永不遍历的桶，搜索结果直接吞掉 ——
    // 站点元数据里父版块被删/被权限隐藏时就是这个形状。
    it('stillFindsCategoryWhoseParentIsGone', 0, () => {
      const tree: TopicCategory[] = [category(1, '正常'), category(99, '孤儿版块', 12345)];
      const hits: CategorySearchHit[] = searchCategories(tree, '孤儿');
      expect(hits.length).assertEqual(1);
      expect(hits[0].category.id).assertEqual(99);
      // 当顶级处理（层级判断可能不准，但绝不能消失），parent 是自身，图标兜底才不崩。
      expect(hits[0].isChild).assertFalse();
      expect(hits[0].parent.id).assertEqual(99);
    });

    // 三级版块（Discourse 的 max_category_nesting 允许 3）必须能搜到。
    // 早先按「父 id 是否存在」分两桶，三级会被塞进一个永不遍历的桶里消失。
    it('findsThirdLevelCategoryWithFullBreadcrumb', 0, () => {
      const tree: TopicCategory[] = [
        category(1, '一级'),
        category(2, '二级', 1),
        category(3, '三级', 2)
      ];
      const hits: CategorySearchHit[] = searchCategories(tree, '三级');
      expect(hits.length).assertEqual(1);
      expect(hits[0].isChild).assertTrue();
      // 面包屑按「顶级 → 直接父」拼，读起来才顺。
      expect(hits[0].breadcrumb).assertEqual('一级 / 二级');
      // 图标兜底取直接父。
      expect(hits[0].parent.id).assertEqual(2);
    });

    // 「未分类」在浏览树里是不显示的（CategoryIndex.topLevelCategories 排除），
    // 搜索也不该把它翻出来，否则会出现一个树上永远找不到的条目。
    it('hidesUncategorizedCategory', 0, () => {
      const tree: TopicCategory[] = [category(1, '未分类'), category(2, '正常版块')];
      expect(searchCategories(tree, '未分类').length).assertEqual(0);
      expect(searchCategories(tree, '正常').length).assertEqual(1);
    });

    // 查询两端的空白要 trim 掉，否则手机输入法常带的尾随空格会让搜索「明明有却搜不到」。
    it('trimsSurroundingWhitespaceInQuery', 0, () => {
      expect(searchCategories(TREE, '  调优  ').length).assertEqual(1);
    });
  });
}
