// 需要 CSRF token 的同源写请求脚本模板。
//
// 抽取前 createFormScript / createPostJsonScript / createUploadScript / createPutScript
// 四个函数各自完整地写了一遍同一套骨架(取 CSRF → 组 fetchOptions → 注入 referrer →
// 回传结果),两两重叠 79%~89%。代价是:CSRF 的取法一旦要改(比如 Discourse 换了
// /session/csrf.json 的形状),得同步改四处,漏一处就是一条写请求静默失败。
//
// 变化点只有五个,全部参数化;骨架一字不动地保留原样——包括 header 的**顺序**。
// 顺序是承重的:这些头是照着抓包逐个对齐的,CF 会看请求指纹,重排可能让写请求被拦。
// 因此各调用方传入的 headerLines 必须与原实现逐行等同,不做"排序整理"。

// 请求 id 占位符由调用方(ArkWebNetworkBridge)在发起时替换成真实 id。
export interface CsrfScriptOptions {
  // 请求 id 占位符字面量。
  requestIdToken: string;
  // new URL(...) 的第一个实参,已是可直接嵌入的 JS 表达式(JSON.stringify 的结果或字面量)。
  urlExpr: string;
  // fetchOptions.method 的值,已含引号或插值。
  methodExpr: string;
  // headers 对象的内容,每项形如 "'Accept': '*/*'"。顺序即生成顺序,不可重排。
  headerLines: string[];
  // 取到 csrf 之后、组 fetchOptions 之前要插入的 JS(上传用它构造 FormData)。空串表示无。
  prelude: string;
  // fetchOptions.body 的 JS 表达式。空串表示该请求不带 body(如 PUT 的空请求)。
  bodyExpr: string;
  // fetchOptions.referrer 的 JS 表达式(JSON.stringify 的结果)。
  referrerExpr: string;
}

export function buildCsrfScript(options: CsrfScriptOptions): string {
  const headers: string = options.headerLines
    .map((line: string): string => `            ${line}`)
    .join(',\n');
  // 带 body 时 headers 的收尾花括号要跟逗号,不带时不跟——保持与原实现完全一致的字面形态。
  const bodyPart: string = options.bodyExpr.length > 0
    ? `,\n          body: ${options.bodyExpr}`
    : '';

  return `(() => {
      const requestId = '${options.requestIdToken}';
      const requestUrl = new URL(${options.urlExpr}, window.location.origin);
      let csrfSource = 'none';
      let csrfLength = 0;
      // reasonKind 是**结构化的失败分类**,不是给用户看的文案:界面层靠它区分「该去重新登录」
      // 与「该检查网络」。CSRF 取不到几乎只有一个原因 —— 会话过期 —— 而把它混进
      // 「fetch 失败」会让界面提示「检查网络」,用户重试多少次都不会成功。
      const fail = (error, reasonKind) => {
        window.ArkDOBridge.onJsonResult(requestId, JSON.stringify({
          statusCode: 0,
          contentType: '',
          body: '',
          errorMessage: String(error),
          failureKind: reasonKind || '',
          csrfSource: csrfSource,
          csrfLength: csrfLength
        }));
      };
      const metaCsrf = () => {
        const el = document.querySelector('meta[name="csrf-token"]');
        return el ? (el.getAttribute('content') || '') : '';
      };
      const readCsrf = () => {
        return fetch(new URL('/session/csrf.json', window.location.origin).toString(), {
          credentials: 'include',
          cache: 'no-store',
          headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
        }).then((r) => r.json()).then((j) => (j && j.csrf) ? j.csrf : '').catch(() => '');
      };
      const readCsrfWithRetry = () => {
        return readCsrf().then((token) => {
          if (token) {
            return token;
          }
          return readCsrf();
        });
      };
      Promise.resolve(readCsrfWithRetry()).then((token) => {
        let csrf = token;
        csrfSource = token ? 'session' : 'none';
        if (!csrf) {
          csrf = metaCsrf();
          csrfSource = csrf ? 'meta' : 'none';
        }
        csrfLength = csrf ? csrf.length : 0;
        // 取不到 CSRF 就 fail-fast,绝不空 token 裸发:Discourse 对无/失效 CSRF 的写请求
        // 一律回 403 BAD CSRF,而 JSON 403 不会被 detectChallenge 识别成挑战(challengeState=NONE),
        // 上层不会触发任何恢复链路,只能眼睁睁看回复失败。取不到多半是会话过期(宿主 cookie 仓里
        // 的 _t 失效),
        // 直接带诊断信息失败,让上层提示重登,比发出一个注定 403 的请求强。
        if (!csrf) {
          fail('CSRF token unavailable source=' + csrfSource + ' - write aborted, session may be expired, please re-login',
            'session_expired');
          return;
        }
${options.prelude}        const fetchOptions = {
          method: ${options.methodExpr},
          credentials: 'include',
          cache: 'no-store',
          headers: {
${headers}
          }${bodyPart}
        };
        const _ref = ${options.referrerExpr};
        if (_ref) {
          fetchOptions.referrer = _ref;
          fetchOptions.referrerPolicy = 'strict-origin-when-cross-origin';
        }
        return fetch(requestUrl.toString(), fetchOptions);
      }).then((response) => {
        response.text().then((body) => {
          window.ArkDOBridge.onJsonResult(requestId, JSON.stringify({
            statusCode: response.status,
            contentType: response.headers.get('content-type') || '',
            cfMitigated: response.headers.get('cf-mitigated') || '',
            loggedOut: response.headers.get('discourse-logged-out') || '',
            body: body,
            csrfSource: csrfSource,
            csrfLength: csrfLength
          }));
        }).catch(fail);
      }).catch(fail);
      return requestId;
    })();`;
}
