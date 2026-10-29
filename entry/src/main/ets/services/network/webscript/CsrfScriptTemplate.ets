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

import { CSRF_CACHE_TTL_MS, CSRF_RETRY_DELAYS_MS } from '../CsrfFailurePolicy';

export interface CsrfScriptOptions {
  // 请求 id 占位符字面量,由调用方(ArkWebNetworkBridge)在发起时替换成真实 id。
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
      // ── CSRF 读取的可观测事实 ─────────────────────────────────────────
      // 这里只记录「试了几次、最后一次看到什么」,**不**判断会话是否过期:分类交给
      // ArkTS 侧的 classifyCsrfFailure(纯函数、可单测),脚本只如实上报现场。
      let csrfAttempts = 0;
      let csrfLastStatus = 0;
      let csrfLastError = '';
      let csrfCfMitigated = '';
      let csrfLoggedOut = '';
      let csrfUsedCache = false;
      // reasonKind 是**结构化的失败分类**,不是给用户看的文案:界面层靠它区分「该去重新登录」
      // 与「该检查网络」。
      const fail = (error, reasonKind) => {
        window.ArkDOBridge.onJsonResult(requestId, JSON.stringify({
          statusCode: 0,
          contentType: '',
          body: '',
          errorMessage: String(error),
          failureKind: reasonKind || '',
          csrfSource: csrfSource,
          csrfLength: csrfLength,
          csrfAttempts: csrfAttempts,
          csrfLastStatus: csrfLastStatus,
          csrfLastError: csrfLastError,
          csrfCfMitigated: csrfCfMitigated,
          csrfLoggedOut: csrfLoggedOut,
          csrfUsedCache: csrfUsedCache
        }));
      };
      const metaCsrf = () => {
        const el = document.querySelector('meta[name="csrf-token"]');
        return el ? (el.getAttribute('content') || '') : '';
      };
      // 单次读取。旧实现把 fetch 失败、非 JSON(CF 挑战页是 HTML)、字段缺失一律
      // catch 成空串,于是三者都被当成「会话过期」。这里逐项留下证据。
      const readCsrfOnce = () => {
        csrfAttempts += 1;
        let request;
        try {
          request = fetch(new URL('/session/csrf.json', window.location.origin).toString(), {
            credentials: 'include',
            cache: 'no-store',
            headers: { 'Accept': 'application/json', 'X-Requested-With': 'XMLHttpRequest' }
          });
        } catch (e) {
          // fetch 对坏 URL / 被禁用的环境会**同步**抛,不会返回 rejected promise。
          csrfLastError = 'transport:' + String((e && e.message) ? e.message : e);
          return Promise.resolve('');
        }
        return request.then((r) => {
          csrfLastStatus = r.status;
          csrfCfMitigated = r.headers.get('cf-mitigated') || '';
          csrfLoggedOut = r.headers.get('discourse-logged-out') || '';
          if (!r.ok) {
            csrfLastError = 'http_' + r.status;
            return '';
          }
          return r.text().then((text) => {
            let parsed = null;
            try {
              parsed = JSON.parse(text);
            } catch (e) {
              // 挑战页/错误页是 HTML,JSON.parse 必抛 —— 这是「盾挡着」,不是会话过期。
              csrfLastError = 'malformed';
              return '';
            }
            if (parsed && parsed.csrf) {
              return String(parsed.csrf);
            }
            csrfLastError = 'missing';
            return '';
          });
        }).catch((e) => {
          csrfLastError = 'transport:' + String((e && e.message) ? e.message : e);
          return '';
        });
      };
      const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
      // 只有**正面证据**才算会话失效,与 CsrfFailurePolicy.classifyCsrfFailure 同一口径。
      const definiteLogout = () => {
        return csrfLoggedOut.length > 0 || csrfLastStatus === 401 ||
          (csrfLastStatus === 403 && csrfCfMitigated.length === 0);
      };
      const readCsrfWithRetry = () => {
        const delays = ${JSON.stringify(CSRF_RETRY_DELAYS_MS)};
        const run = async () => {
          for (let i = 0; i < delays.length; i++) {
            if (delays[i] > 0) {
              await sleep(delays[i]);
            }
            const token = await readCsrfOnce();
            if (token) {
              return token;
            }
            // 服务端明确说没登录就立刻停:再读几次也是同一个结果,还白喂 CF 速率盾。
            if (definiteLogout()) {
              return '';
            }
          }
          return '';
        };
        return run();
      };
      Promise.resolve(readCsrfWithRetry()).then((token) => {
        let csrf = token;
        csrfSource = token ? 'session' : 'none';
        if (!csrf) {
          // 服务端明确说没登录时,缓存里的令牌也不能再用(重新登录会换会话),
          // 否则就是拿一个注定 403 的令牌去发写请求。
          if (definiteLogout()) {
            window.__arkdoCsrfCache = null;
          } else {
            // 读不到时先复用最近一次成功读到的令牌:同一会话内令牌不变,而真机日志里
            // source=none 之后 2.5 秒的写请求照样 200。
            const cache = window.__arkdoCsrfCache;
            const cacheFresh = cache && cache.token && cache.origin === window.location.origin &&
              (Date.now() - cache.at) < ${CSRF_CACHE_TTL_MS};
            if (cacheFresh) {
              csrf = cache.token;
              csrfSource = 'cache';
              csrfUsedCache = true;
            } else {
              csrf = metaCsrf();
              csrfSource = csrf ? 'meta' : 'none';
            }
          }
        }
        csrfLength = csrf ? csrf.length : 0;
        if (csrf && !definiteLogout()) {
          window.__arkdoCsrfCache = { token: csrf, at: Date.now(), origin: window.location.origin };
        }
        // 取不到 CSRF 就 fail-fast,绝不空 token 裸发:Discourse 对无/失效 CSRF 的写请求
        // 一律回 403 BAD CSRF,而 JSON 403 不会被 detectChallenge 识别成挑战(challengeState=NONE),
        // 上层不会触发任何恢复链路。但「取不到」**不等于**「会话过期」—— 分类交给上层,
        // 这里只报 csrf_unavailable 与现场事实。
        if (!csrf) {
          fail('CSRF token unavailable source=' + csrfSource + ' attempts=' + csrfAttempts +
            ' lastStatus=' + csrfLastStatus + ' lastError=' + csrfLastError, 'csrf_unavailable');
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
        // 上面 fail-fast 时 fail() 已经回过执,这里拿到的是 undefined。不加这道闸,
        // response.text() 会再抛一次,同一个 requestId 收到第二个失败回执(日志里表现为
        // 「callback ignored」+ 一条 TypeError 噪声)。
        if (!response) {
          return;
        }
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
