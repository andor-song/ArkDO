import { ChallengeState, NetworkErrorCode, NetworkFailureKind, NetworkResult } from './NetworkTypes';

// NetworkResult 失败态的三个构造器。
//
// 原先这两个函数在 7 个 service 里各复制一份(TopicService/UserProfileService/SiteService/
// UserRelationService/AuthService/BookmarkService/DraftService),且已经开始漂移:
//   - 3 份丢了泛型,把返回类型硬编码成 User|undefined / BookmarkPage / DraftPage;
//   - 1 份把 unexpectedResponse 改名成 unexpected 并换了入参形态。
// 集中到这里后,「失败该长什么样」只有一处定义。

// 把下层(bridge)的失败原样上抛,只换泛型形参。
// 用于「请求本身就没成功」——状态码、挑战态、错误对象全部沿用下层判定,不做二次解释。
//
// notLoggedIn / loggedOutByServer 也必须带上:它们只在桥层按原始响应体判定一次,上层再也
// 补不回来。原先这里只搬四个字段,于是「未登录」这个信息在穿过任何一个 service 的那一刻就
// 丢了 —— 页面判 result.notLoggedIn 恒为 undefined,「去登录」与「重试」两种引导分不开,
// 用户看到的是对一枚有效凭据反复点重试。界面文案映射(UserFacingError)整条 NEED_LOGIN
// 分支就建在这个标志上,漏一趟等于那档永远走不到。
export function forwardFailure<T, S = string>(response: NetworkResult<S>): NetworkResult<T> {
  return {
    success: false,
    statusCode: response.statusCode,
    challengeState: response.challengeState,
    error: response.error,
    notLoggedIn: response.notLoggedIn,
    loggedOutByServer: response.loggedOutByServer
  };
}

// 请求成功但响应不是预期形态(空 body / 非 JSON / 缺关键字段)。
// requiresChallenge 由挑战态推导:被 CF 拦时返回的往往是 HTML,同样会落到这里,
// 需要让上层区分「服务端结构变了」和「该过盾了」。
//
// userReason / failureKind 是给界面文案映射层(UserFacingError)的结构化旁注,默认可省:
// 绝大多数调用点造的确实是「响应读不出来」这种内部失败,界面按状态码给通用引导即可。
// 需要它们的是两类:① 手里已经握着站点写给用户看的原因(postFailure 的 422 文案),
// 不带上就等于在重新构造 error 时把它丢了;② 压根没发请求的本地校验拦截(failureKind
// 标 LOCAL_ABORT),否则 status===0 会被解释成「检查网络」。
export function unexpectedResponse<T>(
  statusCode: number,
  challengeState: ChallengeState,
  message: string,
  userReason?: string,
  failureKind?: NetworkFailureKind
): NetworkResult<T> {
  return {
    success: false,
    statusCode: statusCode,
    challengeState: challengeState,
    error: {
      code: NetworkErrorCode.UNEXPECTED_RESPONSE,
      message: message,
      requiresChallenge: challengeState !== ChallengeState.NONE,
      userReason: userReason !== undefined && userReason.length > 0 ? userReason : undefined,
      failureKind: failureKind
    }
  };
}

// unexpectedResponse 的便捷形态:直接从原始响应取状态码与挑战态,省去调用方手动拆包。
export function unexpectedFrom<T>(response: NetworkResult<string>, message: string,
  userReason?: string, failureKind?: NetworkFailureKind): NetworkResult<T> {
  return unexpectedResponse<T>(response.statusCode, response.challengeState, message, userReason, failureKind);
}
