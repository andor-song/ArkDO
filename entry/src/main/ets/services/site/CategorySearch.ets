import { TopicCategory } from '../../models/Topic';

/**
 * 版块搜索的纯函数层。
 *
 * 为什么要有它：标签页早就有搜索框（几百个标签没有搜索够不着），版块页却只能滚 ——
 * 同一个抽屉里两页的能力不对称，用户会以为版块只有那么几个。
 *
 * 匹配规则刻意简单：**只按名称做不区分大小写的子串匹配**，不做拼音、不做首字母。
 * 理由是否则得引入词库（体积 + 维护成本），而版块名本来就是中文短语，直接搜两个字就够。
 * 命中子版块时把它连同父版块一起返回 —— 只给一个「问与答」而不说是哪个父版块下的，
 * 同名子版块（例如多个分类下都有「其他」）就分不开了。
 */

export interface CategorySearchHit {
  category: TopicCategory;
  // 是否子版块（决定缩进与字号）。
  isChild: boolean;
  // 图标兜底与面包屑用的父版块；顶级版块传自身（与 CategoryRow 的既有约定一致）。
  parent: TopicCategory;
  // 祖先路径（不含自身，用「 / 」连接）。顶级版块为空串。
  // 搜索结果里同名子版块（多个分类下都有「其他」）只能靠它分辨 —— 只给名字的话
  // 两行长得一模一样，用户没法选。
  breadcrumb: string;
}

function matches(name: string, needle: string): boolean {
  return name.toLowerCase().indexOf(needle) >= 0;
}

// Discourse 默认的「未分类」版块：浏览树里不显示（CategoryIndex.topLevelCategories 同样排除），
// 搜索也不该把它翻出来 —— 否则会出现一个树上永远找不到的条目。
// 与 CategoryIndex.isUncategorized 同一口径（那边带网络依赖，这里是纯函数，不能直接引）。
function isUncategorized(category: TopicCategory): boolean {
  const slug: string = (category.slug ?? '').trim().toLowerCase();
  if (slug === 'uncategorized') {
    return true;
  }
  const name: string = category.name.trim();
  return name === '未分类' || name.toLowerCase() === 'uncategorized';
}

/**
 * 在版块集合里搜索。空查询返回空数组（调用方据此回退到常规树）。
 *
 * 顺序：先顶级命中（按原顺序），再子版块命中（按父版块的顺序）。这样结果里
 * 「大类」永远排在「小类」前面，符合从粗到细的浏览直觉。
 */
export function searchCategories(categories: TopicCategory[], query: string): CategorySearchHit[] {
  const needle: string = query.trim().toLowerCase();
  if (needle.length === 0) {
    return [];
  }

  // id → 版块。用来解析父链，也用来判断「父版块是否真的存在」。
  // 站点元数据里偶有父版块被删/被权限隐藏、子版块仍留在列表里的情况 ——
  // 那种版块按顶级处理（宁可层级判断错，也不能让它在搜索里消失）。
  const byId: Map<number, TopicCategory> = new Map<number, TopicCategory>();
  for (let index: number = 0; index < categories.length; index++) {
    byId.set(categories[index].id, categories[index]);
  }

  // 父链（从直接父到顶级）。长度上限取分类总数，天然挡住异常数据造成的环。
  const ancestry = (category: TopicCategory): TopicCategory[] => {
    const chain: TopicCategory[] = [];
    let cursor: TopicCategory | undefined = category;
    for (let guard: number = 0; guard < categories.length; guard++) {
      const parentId: number | undefined = cursor.parentCategoryId;
      if (parentId === undefined || parentId === 0) {
        break;
      }
      const parent: TopicCategory | undefined = byId.get(parentId);
      if (parent === undefined) {
        break;
      }
      chain.push(parent);
      cursor = parent;
    }
    return chain;
  };

  // 顶级命中排在子版块命中的前面（从粗到细）。两趟扫描而不是排序，
  // 是为了在各自组内保持 categories 原本的顺序（与站点侧栏一致）。
  const topHits: CategorySearchHit[] = [];
  const childHits: CategorySearchHit[] = [];
  for (let index: number = 0; index < categories.length; index++) {
    const category: TopicCategory = categories[index];
    if (isUncategorized(category)) {
      continue;
    }
    if (!matches(category.name, needle)) {
      continue;
    }
    const chain: TopicCategory[] = ancestry(category);
    if (chain.length === 0) {
      topHits.push({ category: category, isChild: false, parent: category, breadcrumb: '' });
      continue;
    }
    // 面包屑从顶级往直接父排，读起来才是「父 / 子」的顺序。
    const names: string[] = [];
    for (let depth: number = chain.length - 1; depth >= 0; depth--) {
      names.push(chain[depth].name);
    }
    childHits.push({
      category: category,
      isChild: true,
      parent: chain[0],
      breadcrumb: names.join(' / ')
    });
  }
  return topHits.concat(childHits);
}
