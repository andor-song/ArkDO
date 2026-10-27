import { describe, it, expect } from '@ohos/hypium';
import {
  ChallengeState, NetworkErrorCode, NetworkFailureKind, NetworkResult
} from '../main/ets/services/network/NetworkTypes';
import {
  classifyFailure, FailureCause, FailureCopy, friendlyFailure, friendlyWebLoadFailure, rawFailure
} from '../main/ets/services/network/UserFacingError';

// 界面文案绝不能出现的内部词。这些词在桥层/service 层的 message 里到处都是
// (「ArkWeb 宿主尚未就绪。」「站点帖子列表响应不是有效 JSON。」),而界面曾经原样透出。
// 用一张表而不是逐句断言:新增一档文案时,这条会自动兜住「顺手把内部名词写回去」。
const INTERNAL_WORDS: string[] = [
  'ArkWeb', '宿主', 'JSON', 'cookie', 'Cookie', 'token', 'Token', '会话',
  'HTTP', '状态码', '站点', 'WebView', 'webview', 'CSRF'
];

const COPY: FailureCopy = { subject: '内容', action: '加载' };

// 显式声明而不是内联字面量类型:ArkTS 的 arkts-no-untyped-obj-literals 要求对象字面量对应
// 已声明的 class/interface,参数上写匿名结构类型会让**所有**调用点的字面量报错。
// (这条只有真编译器抓得到,本地 Node harness 会照跑不误 —— 所以测试文件也必须过 CompileArkTS。)
interface FailureSpec {
  code?: NetworkErrorCode;
  message?: string;
  requiresChallenge?: boolean;
  failureKind?: NetworkFailureKind;
  userReason?: string;
}

function failed<T>(statusCode: number, error?: FailureSpec, notLoggedIn?: boolean): NetworkResult<T> {
  const result: NetworkResult<T> = {
    success: false,
    statusCode: statusCode,
    challengeState: ChallengeState.NONE,
    notLoggedIn: notLoggedIn
  };
  if (error !== undefined) {
    result.error = {
      code: error.code !== undefined ? error.code : NetworkErrorCode.NETWORK_FAILURE,
      message: error.message !== undefined ? error.message : '',
      requiresChallenge: error.requiresChallenge !== undefined ? error.requiresChallenge : false,
      failureKind: error.failureKind,
      userReason: error.userReason
    };
  }
  return result;
}

function assertNoInternalWords(text: string): void {
  for (let index: number = 0; index < INTERNAL_WORDS.length; index++) {
    const word: string = INTERNAL_WORDS[index];
    // 断言消息里带上命中的词:失败时能直接看出是哪句文案漏了哪个词。
    expect(`${text} | leaked=${text.indexOf(word) >= 0 ? word : ''}`).assertEqual(`${text} | leaked=`);
  }
}

export default function userFacingErrorTest() {
  describe('userFacingErrorTest', () => {
    // 挑战态是流量层拦截,必须先于任何业务原因 —— 上层还要靠它拉过盾流程,
    // 文案不能把「去验证」说成「内容不存在」。
    it('challengeBeatsEveryOtherSignal', 0, () => {
      const response: NetworkResult<string> = failed<string>(403, {
        code: NetworkErrorCode.CHALLENGE_REQUIRED,
        message: '需要完成可见 Cloudflare 验证后重试。',
        requiresChallenge: true,
        userReason: '站点说这句'
      });
      response.challengeState = ChallengeState.REQUIRED;

      expect(classifyFailure(response)).assertEqual(FailureCause.CHALLENGE);
      const text: string = friendlyFailure(response, COPY);
      expect(text).assertContain('访问验证');
      assertNoInternalWords(text);
    });

    // 桥把挑战态塞在 error.requiresChallenge 上、challengeState 仍是 NONE 的路径也存在
    // (unexpectedResponse 由挑战态推导时两者一致,但手写失败对象不一定)。
    // 只认 challengeState 会在那条路上漏判,于是「去验证」被说成「读不出来」。
    it('challengeFlagOnErrorAloneIsEnough', 0, () => {
      const response: NetworkResult<string> = failed<string>(403, {
        message: 'x', requiresChallenge: true
      });

      expect(classifyFailure(response)).assertEqual(FailureCause.CHALLENGE);
    });

    // Discourse 未登录时会在响应体里带「您需要登录才能执行此操作。」,它也会被标成 userReason。
    // 若先认 userReason,唯一可执行的引导(去登录)就被擦成一句没有下文的话。
    it('needLoginBeatsServerReason', 0, () => {
      const response: NetworkResult<string> = failed<string>(403, {
        message: '站点返回 HTTP 403。',
        userReason: '您需要登录才能执行此操作。'
      }, true);

      expect(classifyFailure(response)).assertEqual(FailureCause.NEED_LOGIN);
      const text: string = friendlyFailure(response, COPY);
      expect(text).assertContain('登录');
      assertNoInternalWords(text);
    });

    // 403 但不是 not_logged_in(游客限制/信任级别不够):不能谎报成「没登录」,
    // 否则用户会去重登一遍再撞同一堵墙。
    it('plainForbiddenIsNotReportedAsLoggedOut', 0, () => {
      const response: NetworkResult<string> = failed<string>(403, {
        message: '站点返回 HTTP 403。'
      });

      expect(classifyFailure(response)).assertEqual(FailureCause.FORBIDDEN);
      const text: string = friendlyFailure(response, COPY);
      expect(text).assertContain('权限');
      expect(text.indexOf('登录') < 0).assertTrue();
      assertNoInternalWords(text);
    });

    // statusCode===0 的五种成因在用户语言里引导完全不同,靠 failureKind 区分,不靠 message。
    it('zeroStatusIsSplitByFailureKind', 0, () => {
      expect(classifyFailure(failed<string>(0, {
        message: '尚未选择论坛。', failureKind: NetworkFailureKind.NO_ACTIVE_SITE
      }))).assertEqual(FailureCause.NO_ACTIVE_SITE);

      expect(classifyFailure(failed<string>(0, {
        message: 'ArkWeb 宿主尚未就绪。', failureKind: NetworkFailureKind.HOST_NOT_READY
      }))).assertEqual(FailureCause.HOST_NOT_READY);

      expect(classifyFailure(failed<string>(0, {
        message: 'TypeError: Failed to fetch', failureKind: NetworkFailureKind.TRANSPORT
      }))).assertEqual(FailureCause.NETWORK);

      // 没标 kind 的按最一般的网络失败处理:猜错方向比说「检查网络」更糟。
      expect(classifyFailure(failed<string>(0, {
        message: 'ArkWeb 请求失败。'
      }))).assertEqual(FailureCause.NETWORK);
    });

    // 写请求拿不到 CSRF = 会话已过期。这条**必须**走「重新登录」而不是「检查网络」:
    // 后者会让用户在网络设置里白折腾,而重试永远不会成功。判定靠脚本给的结构化 failureKind,
    // 不靠 errorMessage 里有没有 'CSRF'(那是给日志看的,不是契约)。
    it('expiredSessionAsksForReloginNotNetworkCheck', 0, () => {
      const response: NetworkResult<string> = failed<string>(0, {
        message: 'CSRF token unavailable source=none - write aborted, session may be expired, please re-login',
        failureKind: NetworkFailureKind.SESSION_EXPIRED
      });

      expect(classifyFailure(response)).assertEqual(FailureCause.NEED_LOGIN);
      const text: string = friendlyFailure(response, COPY);
      expect(text).assertContain('登录');
      expect(text.indexOf('网络') < 0).assertTrue();
      assertNoInternalWords(text);
    });

    // 本仓自己拦下没发请求的(本地校验/切了论坛),说「检查网络」会把用户往反方向领,
    // 而且重试永远不会成功。
    it('localAbortDoesNotBlameTheNetwork', 0, () => {
      const response: NetworkResult<string> = failed<string>(0, {
        message: '已切换论坛,丢弃上一个论坛的阅读上报。',
        failureKind: NetworkFailureKind.LOCAL_ABORT
      });

      expect(classifyFailure(response)).assertEqual(FailureCause.LOCAL_ABORT);
      const text: string = friendlyFailure(response, COPY);
      expect(text.indexOf('网络') < 0).assertTrue();
      assertNoInternalWords(text);
    });

    // 站点给的原因必须原样透出:它说明了「踩了哪条规则」,比任何模板都有用。
    it('serverReasonIsPassedThroughVerbatim', 0, () => {
      const reason: string = '附件数量超过限制';
      const response: NetworkResult<string> = failed<string>(422, {
        message: '站点返回 HTTP 422。', userReason: reason
      });

      expect(classifyFailure(response)).assertEqual(FailureCause.USER_REASON);
      expect(friendlyFailure(response, COPY)).assertEqual(reason);
    });

    // 状态码 → 分类的完整对照。这张表是「界面按结构分类」的契约:
    // 任何一档被改到别的分支上,这里立刻红。
    it('mapsStatusCodesToCauses', 0, () => {
      expect(classifyFailure(failed<string>(404))).assertEqual(FailureCause.NOT_FOUND);
      expect(classifyFailure(failed<string>(409))).assertEqual(FailureCause.CONFLICT);
      expect(classifyFailure(failed<string>(429))).assertEqual(FailureCause.RATE_LIMIT);
      expect(classifyFailure(failed<string>(400))).assertEqual(FailureCause.REJECTED);
      expect(classifyFailure(failed<string>(422))).assertEqual(FailureCause.REJECTED);
      expect(classifyFailure(failed<string>(500))).assertEqual(FailureCause.UPSTREAM);
      expect(classifyFailure(failed<string>(502))).assertEqual(FailureCause.UPSTREAM);
      expect(classifyFailure(failed<string>(418))).assertEqual(FailureCause.UNKNOWN);
    });

    // 2xx 但读不出结构:站点改版/插件裁剪字段。说「检查网络」是错的(网络明明通了),
    // 说「稍后重试」才是用户能做的。
    it('successfulResponseWithBadShapeIsMalformedNotNetwork', 0, () => {
      const response: NetworkResult<string> = failed<string>(200, {
        code: NetworkErrorCode.UNEXPECTED_RESPONSE,
        message: '站点帖子列表响应不是有效 JSON。'
      });

      expect(classifyFailure(response)).assertEqual(FailureCause.MALFORMED);
      const text: string = friendlyFailure(response, COPY);
      expect(text.indexOf('网络') < 0).assertTrue();
      assertNoInternalWords(text);
    });

    // 连 error 都没有的失败(理论上不该出现,但兜底不能崩、也不能返回空串 ——
    // 空串在界面上等于「点了没反应」)。
    it('toleratesMissingErrorObject', 0, () => {
      const response: NetworkResult<string> = failed<string>(0);

      expect(classifyFailure(response)).assertEqual(FailureCause.NETWORK);
      expect(friendlyFailure(response, COPY).length > 0).assertTrue();
    });

    // 一张覆盖所有分类的矩阵:任何一档的文案都不许出现内部词。
    // 单条断言写死句子会在下次改措辞时变成维护负担,这里只钉「不泄漏」这一条性质。
    it('neverLeaksInternalWordsAcrossAllCauses', 0, () => {
      const samples: NetworkResult<string>[] = [
        failed<string>(0, { message: '尚未选择论坛。', failureKind: NetworkFailureKind.NO_ACTIVE_SITE }),
        failed<string>(0, { message: 'ArkWeb 宿主尚未就绪。', failureKind: NetworkFailureKind.HOST_NOT_READY }),
        failed<string>(0, { message: 'TypeError: Failed to fetch', failureKind: NetworkFailureKind.TRANSPORT }),
        failed<string>(0, { message: 'ArkWeb 请求超时。', failureKind: NetworkFailureKind.TIMEOUT }),
        failed<string>(0, { message: 'ArkWeb 脚本执行失败。', failureKind: NetworkFailureKind.SCRIPT_FAILURE }),
        failed<string>(0, { message: '已切换论坛,丢弃上一个论坛的阅读上报。', failureKind: NetworkFailureKind.LOCAL_ABORT }),
        failed<string>(403, { message: '站点返回 HTTP 403。' }),
        failed<string>(404, { message: '站点返回 HTTP 404。' }),
        failed<string>(409, { message: '站点返回 HTTP 409。' }),
        failed<string>(429, { message: '站点返回 HTTP 429。' }),
        failed<string>(422, { message: '站点返回 HTTP 422。' }),
        failed<string>(500, { message: '站点返回 HTTP 500。' }),
        failed<string>(200, { code: NetworkErrorCode.UNEXPECTED_RESPONSE, message: '站点帖子详情响应不是有效 JSON。' }),
        failed<string>(0, { message: 'CSRF token unavailable source=meta' })
      ];
      for (let index: number = 0; index < samples.length; index++) {
        assertNoInternalWords(friendlyFailure(samples[index], { subject: '帖子详情', action: '加载' }));
      }
    });

    // 界面不再显示 error.message,排查就全靠这一行。它必须带着原始文案与分类字段,
    // 否则「网络快照」只剩探针结果,用户报「点了没反应」时无从下手。
    it('rawFailureKeepsOriginalMessageAndClassification', 0, () => {
      const response: NetworkResult<string> = failed<string>(0, {
        message: 'ArkWeb 宿主尚未就绪。',
        failureKind: NetworkFailureKind.HOST_NOT_READY
      });
      const raw: string = rawFailure(response);

      expect(raw).assertContain('ArkWeb 宿主尚未就绪。');
      expect(raw).assertContain('host_not_ready');
      expect(raw).assertContain('status=0');
    });

    // 空 message 不能变成 `errMsg=` 后面什么都没有 —— 那在日志里与「截断了」分不开。
    it('rawFailureMarksEmptyMessageExplicitly', 0, () => {
      expect(rawFailure(failed<string>(500))).assertContain('errMsg=(empty)');
    });

    // 网页加载错误页原先把 ERR_NAME_NOT_RESOLVED 这类引擎串直接显示给用户。
    // 现在按错误码说人话,且每句都要给出下一步(这类页面除了重试没有别的出口)。
    it('translatesWebLoadErrorCodesToActionableCopy', 0, () => {
      // -105 是本仓最常见的一条(linux.do 的 DNS 在国内被污染):必须指向 DoH。
      expect(friendlyWebLoadFailure(-105)).assertContain('DoH');
      expect(friendlyWebLoadFailure(-106)).assertContain('网络');
      expect(friendlyWebLoadFailure(-7)).assertContain('超时');
      expect(friendlyWebLoadFailure(-118)).assertContain('超时');
      // CF 边缘间歇性 RST:要明确「可以再试」,而不是让用户以为站点挂了。
      expect(friendlyWebLoadFailure(-101)).assertContain('重试');
      expect(friendlyWebLoadFailure(-102)).assertContain('代理');
      // 证书错误绝不能引导「继续访问」——那正是中间人攻击的样子。
      const cert: string = friendlyWebLoadFailure(-200);
      expect(cert).assertContain('证书');
      expect(cert.indexOf('继续') < 0).assertTrue();
      // 未知码要有兜底,不能返回空串(空串在界面上等于没有错误页)。
      expect(friendlyWebLoadFailure(-9999).length > 0).assertTrue();
      expect(friendlyWebLoadFailure(0).length > 0).assertTrue();
    });

    // 错误页同样不许泄漏引擎内部串。这张表就是「界面文案」与「日志原文」的分界线。
    it('webLoadCopyNeverLeaksEngineStrings', 0, () => {
      const codes: number[] = [-7, -100, -101, -102, -105, -106, -109, -118, -200, -201, -202, 0, -9999];
      for (let index: number = 0; index < codes.length; index++) {
        const text: string = friendlyWebLoadFailure(codes[index]);
        expect(text.indexOf('ERR_') < 0).assertTrue();
        assertNoInternalWords(text);
      }
    });

    // 端到端锚点:分类层与**真实产出方**之间不能靠「我以为它标了」维系。
    // 这里直接拿桥造出来的失败对象喂映射层 —— 桥改了标注而映射层没跟上,这条会红。
    // (桥的构造点在 ArkWebNetworkBridge.test 里另有断言;此处只钉「接得上」。)
    it('consumesFailureObjectsShapedLikeTheBridgeEmits', 0, () => {
      // 桥的 hostNotReadyFailure / noActiveSiteFailure / 挑战分支 / 非 2xx 分支的实际形态。
      const hostNotReady: NetworkResult<string> = failed<string>(0, {
        code: NetworkErrorCode.NETWORK_FAILURE,
        message: 'ArkWeb 宿主尚未就绪。',
        failureKind: NetworkFailureKind.HOST_NOT_READY
      });
      expect(friendlyFailure(hostNotReady, COPY)).assertEqual('正在准备请求环境，请稍后重试');

      const noSite: NetworkResult<string> = failed<string>(0, {
        code: NetworkErrorCode.NETWORK_FAILURE,
        message: '尚未选择论坛。',
        failureKind: NetworkFailureKind.NO_ACTIVE_SITE
      });
      expect(friendlyFailure(noSite, COPY)).assertContain('添加论坛');

      const challenge: NetworkResult<string> = failed<string>(403, {
        code: NetworkErrorCode.CHALLENGE_REQUIRED,
        message: '需要完成可见 Cloudflare 验证后重试。',
        requiresChallenge: true
      });
      challenge.challengeState = ChallengeState.REQUIRED;
      expect(friendlyFailure(challenge, COPY)).assertContain('访问验证');

      // 桥在非 2xx 分支解析 body 后标出的站点原因(422 校验)。
      const rejected: NetworkResult<string> = failed<string>(422, {
        code: NetworkErrorCode.UNEXPECTED_RESPONSE,
        message: '站点返回 HTTP 422。',
        userReason: '附件数量超过限制'
      });
      expect(friendlyFailure(rejected, COPY)).assertEqual('附件数量超过限制');
    });
  });
}
