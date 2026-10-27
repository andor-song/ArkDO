import { describe, it, expect } from '@ohos/hypium';
import {
  avatarGap,
  AVATAR_SIZE_DEFAULT,
  AVATAR_SIZE_MAX,
  AVATAR_SIZE_MIN,
  blurbGap,
  clampAvatarSize,
  clampLineHeightRatio,
  clampRowPadding,
  clampTitleFontSize,
  inlineIconGap,
  inlineIconSize,
  LINE_HEIGHT_RATIO_DEFAULT,
  LINE_HEIGHT_RATIO_MAX,
  LINE_HEIGHT_RATIO_MIN,
  metaRowGap,
  normalizeTitleFontWeight,
  ROW_PADDING_DEFAULT,
  ROW_PADDING_MAX,
  ROW_PADDING_MIN,
  secondaryFontSize,
  TITLE_FONT_SIZE_DEFAULT,
  TITLE_FONT_SIZE_MAX,
  TITLE_FONT_SIZE_MIN,
  TITLE_FONT_WEIGHT_MEDIUM,
  TITLE_FONT_WEIGHT_REGULAR,
  TITLE_FONT_WEIGHT_SEMI_BOLD,
  TITLE_FONT_WEIGHT_DEFAULT,
  titleLineHeight,
  unreadBadgeFontSize,
  unreadBadgeRadius,
  unseenDotFontSize
} from '../main/ets/common/theme/TopicListStylePrefs';

export default function topicListStyleTest() {
  describe('topicListStyleTest', () => {
    // 这一组是回归护栏，但**拆成两段**才诚实：
    // ① 自 72c43e4「列表样式可调」以来从未改过的那些派生值，必须逐像素等于改造前 TopicListItem
    //    里的硬编码数字 —— 不动设置的老用户升级后列表不该"自己变了样"。
    // ② 之后被有意调紧的三项（头像间距随 24a1ef2 头像 48→40 变 7；meta/摘要间距随 7c35f03
    //    行留白 8→5 变 4）钉的是**当前默认值**。它们已经不是"还原硬编码"了，写成那样只会让人
    //    以为改动是回归：上一版正是这样，avatarGap 写着 8、metaRowGap 写着 3，而真实默认是 7 和 4 ——
    //    用例在第一条断言处就抛，后面每一条有没有过期根本看不见。
    it('defaultsReproduceLegacyHardcodedMetrics', 0, () => {
      expect(TITLE_FONT_SIZE_DEFAULT).assertEqual(17);
      expect(titleLineHeight(TITLE_FONT_SIZE_DEFAULT, LINE_HEIGHT_RATIO_DEFAULT)).assertEqual(23);
      expect(secondaryFontSize(TITLE_FONT_SIZE_DEFAULT)).assertEqual(13);
      expect(unreadBadgeFontSize(TITLE_FONT_SIZE_DEFAULT)).assertEqual(12);
      expect(unreadBadgeRadius(unreadBadgeFontSize(TITLE_FONT_SIZE_DEFAULT))).assertEqual(9);
      expect(unseenDotFontSize(TITLE_FONT_SIZE_DEFAULT)).assertEqual(8);
      expect(inlineIconSize(TITLE_FONT_SIZE_DEFAULT)).assertEqual(15);
      expect(inlineIconGap(inlineIconSize(TITLE_FONT_SIZE_DEFAULT))).assertEqual(5);
    });

    // ② 密度调紧后的当前默认。改动都有明确意图与 commit，这里的作用是：下次再调时**必须**
    // 主动来改这一组，而不是让它悄悄红成"测试坏了"。
    it('densityRetunedDefaultsPinCurrentValues', 0, () => {
      // 头像 40 → 间距 40/6 = 6.67 → 7（头像 48 时代是 8）。
      expect(avatarGap(AVATAR_SIZE_DEFAULT)).assertEqual(7);
      // 行留白 5 → meta 5/2 = 2.5 → 下限 4；摘要 5*3/4 = 3.75 → 4。
      expect(metaRowGap(ROW_PADDING_DEFAULT)).assertEqual(4);
      expect(blurbGap(ROW_PADDING_DEFAULT)).assertEqual(4);
    });

    it('clampsTitleFontSizeToRange', 0, () => {
      expect(clampTitleFontSize(4)).assertEqual(TITLE_FONT_SIZE_MIN);
      expect(clampTitleFontSize(99)).assertEqual(TITLE_FONT_SIZE_MAX);
      expect(clampTitleFontSize(16.4)).assertEqual(16);
    });

    it('clampsRowPaddingToRange', 0, () => {
      expect(clampRowPadding(0)).assertEqual(ROW_PADDING_MIN);
      expect(clampRowPadding(500)).assertEqual(ROW_PADDING_MAX);
    });

    it('clampsAvatarSizeToRange', 0, () => {
      expect(clampAvatarSize(8)).assertEqual(AVATAR_SIZE_MIN);
      expect(clampAvatarSize(200)).assertEqual(AVATAR_SIZE_MAX);
    });

    it('clampsLineHeightRatioAndRoundsToTwoDecimals', 0, () => {
      expect(clampLineHeightRatio(0.5)).assertEqual(LINE_HEIGHT_RATIO_MIN);
      expect(clampLineHeightRatio(9)).assertEqual(LINE_HEIGHT_RATIO_MAX);
      // 滑块步进 0.05 的浮点累加会攒出 1.3500000000000003 这类值,不收敛就会一路写进 preferences。
      expect(clampLineHeightRatio(1.3500000000000003)).assertEqual(1.35);
    });

    // 非法值(NaN/Infinity)可能来自被改坏的 preferences 文件,不能让它们把布局撑爆。
    it('fallsBackToDefaultsOnNonFiniteInput', 0, () => {
      expect(clampTitleFontSize(NaN)).assertEqual(TITLE_FONT_SIZE_DEFAULT);
      expect(clampRowPadding(Infinity)).assertEqual(ROW_PADDING_DEFAULT);
      expect(clampAvatarSize(NaN)).assertEqual(AVATAR_SIZE_DEFAULT);
      expect(clampLineHeightRatio(NaN)).assertEqual(LINE_HEIGHT_RATIO_DEFAULT);
    });

    // 字重只认三个值,不做就近取整:450 不该悄悄变成 400 或 500 的某一个"看起来对"的结果。
    //
    // MEDIUM 那一行是这次的回归点:24a1ef2 把脏值回退从 MEDIUM 改成 REGULAR 时没把它列进接受集,
    // 于是设置页上「中等」这个真实存在的档位一点就跳回「常规」。
    //
    // 别把这次漏网记成"用例被改绿了":旧断言 450 → MEDIUM 走的是回退分支,回退值一改成 400,
    // 它当场就该红。真实原因是这套单测从没有自动化的跑测入口 —— 红而无人知晓。
    // 这次补的是**正面**断言 500 → 500:原先"这一档活着"只是回退值的副产品,从没被直接钉过。
    it('acceptsOnlyKnownFontWeights', 0, () => {
      expect(normalizeTitleFontWeight(TITLE_FONT_WEIGHT_REGULAR)).assertEqual(TITLE_FONT_WEIGHT_REGULAR);
      expect(normalizeTitleFontWeight(TITLE_FONT_WEIGHT_MEDIUM)).assertEqual(TITLE_FONT_WEIGHT_MEDIUM);
      expect(normalizeTitleFontWeight(TITLE_FONT_WEIGHT_SEMI_BOLD)).assertEqual(TITLE_FONT_WEIGHT_SEMI_BOLD);
      expect(normalizeTitleFontWeight(450)).assertEqual(TITLE_FONT_WEIGHT_DEFAULT);
      expect(normalizeTitleFontWeight(NaN)).assertEqual(TITLE_FONT_WEIGHT_DEFAULT);
    });

    // 行高必须随字号一起长:存倍率而非绝对值就是为了这个。
    it('scalesLineHeightWithFontSize', 0, () => {
      expect(titleLineHeight(TITLE_FONT_SIZE_MAX, LINE_HEIGHT_RATIO_DEFAULT))
        .assertLarger(titleLineHeight(TITLE_FONT_SIZE_MIN, LINE_HEIGHT_RATIO_DEFAULT));
      expect(titleLineHeight(TITLE_FONT_SIZE_DEFAULT, LINE_HEIGHT_RATIO_MAX))
        .assertLarger(titleLineHeight(TITLE_FONT_SIZE_DEFAULT, LINE_HEIGHT_RATIO_MIN));
      // 越界入参也得先钳制再算,不能算出个越界行高。
      expect(titleLineHeight(999, 9)).assertEqual(Math.round(TITLE_FONT_SIZE_MAX * LINE_HEIGHT_RATIO_MAX));
    });

    // 次要文字始终小于标题,否则层次塌掉;字号拉满时也不许越过 17。
    it('keepsSecondaryTextBelowTitleAcrossRange', 0, () => {
      for (let size: number = TITLE_FONT_SIZE_MIN; size <= TITLE_FONT_SIZE_MAX; size++) {
        expect(secondaryFontSize(size) < size).assertTrue();
        expect(unreadBadgeFontSize(size) < size).assertTrue();
        expect(unseenDotFontSize(size) < size).assertTrue();
      }
    });

    // 极端设置下派生值不能塌成 0(0 高的间距 / 0 边长的图标会让整行看着像坏了)。
    it('keepsDerivedMetricsPositiveAtExtremes', 0, () => {
      expect(metaRowGap(ROW_PADDING_MIN) > 0).assertTrue();
      expect(blurbGap(ROW_PADDING_MIN) > 0).assertTrue();
      expect(inlineIconSize(TITLE_FONT_SIZE_MIN) > 0).assertTrue();
      expect(inlineIconGap(inlineIconSize(TITLE_FONT_SIZE_MIN)) > 0).assertTrue();
      expect(avatarGap(AVATAR_SIZE_MIN) > 0).assertTrue();
      expect(unreadBadgeRadius(unreadBadgeFontSize(TITLE_FONT_SIZE_MIN)) > 0).assertTrue();
    });
  });
}
