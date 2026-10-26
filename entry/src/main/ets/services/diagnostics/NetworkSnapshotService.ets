import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { AppConstants } from '../../common/constants/AppConstants';
import { DohManager, DohServer } from '../network/DohManager';
import { WebSessionManager } from '../web/WebSessionManager';
import { AuthTokenStore, AuthTokenSnapshot } from '../session/AuthTokenStore';
import { FileLogger } from '../logging/FileLogger';
import { Log } from '../logging/Log';

const LOG_TAG: string = '[ArkDO][NetSnapshot]';
const PROBE_TIMEOUT_MS: number = 6000;
// 摘录日志时只留关键行,并排除响应体(verbose 下正文会把现场淹掉)。
const TAIL_LINE_LIMIT: number = 25;

/**
 * 一键网络快照：把「当时网络为什么不通」需要的证据一次性采集下来。
 *
 * 起因：用户报「杀掉后台 + 某个 Wi-Fi 下一直刷不出来」，而日志只留 3MB、几小时就滚掉，
 * 隔天再查没有现场。这里把四类信息并排放好，一次点击即可导出/复制：
 *   1) DoH 配置与**实测**（所有 DNS 是否走 DoH、当前条目、能否解析出结果）
 *   2) **直连**实测（绕开 DoH，用来区分「DoH 不通」还是「整条网络不通」）
 *   3) 登录/cookie 现状（`_t` / `cf_clearance` 存在性——掉登录与 CF 都看这两个）
 *   4) 最近的关键日志行（宿主加载、会话判定、网络失败、挑战）
 * 报告同时写入日志文件，所以「导出日志」也会带上它。
 */
export class NetworkSnapshotService {
  static async collect(context: common.Context): Promise<string> {
    const lines: string[] = [];
    lines.push(`[网络快照] ${new Date().toISOString()}`);
    lines.push(`站点 ${AppConstants.BASE_URL}`);

    const enabled: boolean = DohManager.isEnabled(context);
    const mode: string = String(DohManager.getMode(context));
    const active: DohServer = DohManager.getActiveServer(context);
    lines.push(`DoH 配置 enabled=${enabled} mode=${mode} active=${active.name} url=${active.url}`);
    lines.push(`DoH 实测 ${await NetworkSnapshotService.probeDoh(active.url)}`);
    lines.push(`直连实测 ${await NetworkSnapshotService.probeDirect()}`);

    const cfPresence: string = String(WebSessionManager.getCookiePresenceForUrl(AppConstants.BASE_URL, 'cf_clearance'));
    lines.push(`Cookie cf_clearance=${cfPresence}`);
    // 认证 cookie 单独成段(而不是并进上面那行):要说的东西不止"有没有"——还包括
    // "是哪一枚""备份是不是同一枚""有没有被判死过",一行塞不下,而这几项正是掉登录的判据。
    lines.push(AuthTokenStoreSummary.describe(await AuthTokenStore.snapshot(context)));

    lines.push('--- 最近关键日志 ---');
    const tail: string[] = FileLogger.tailLines(800);
    const kept: string[] = [];
    for (let index: number = 0; index < tail.length; index++) {
      const line: string = tail[index];
      if (line.indexOf('[ArkDO]') < 0 || line.indexOf('[Body]') >= 0 || line.indexOf('[MessageBus]') >= 0) {
        continue;
      }
      kept.push(line);
    }
    const recent: string[] = kept.length <= TAIL_LINE_LIMIT ? kept : kept.slice(kept.length - TAIL_LINE_LIMIT);
    for (let index: number = 0; index < recent.length; index++) {
      lines.push(recent[index]);
    }

    const report: string = lines.join('\n');
    Log.i(`${LOG_TAG} collected\n${report}`);
    return report;
  }

  // DoH 实测：JSON 接口带 name/type，能解析出答案才算通。
  private static async probeDoh(baseUrl: string): Promise<string> {
    if (baseUrl.length === 0) {
      return '未配置 DoH 条目';
    }
    const separator: string = baseUrl.indexOf('?') >= 0 ? '&' : '?';
    return NetworkSnapshotService.probe(`${baseUrl}${separator}name=linux.do&type=A`, 'application/dns-json', true);
  }

  // 直连实测：复用宿主引导页那个极轻的同源文档，顺带验证会话链路。
  private static async probeDirect(): Promise<string> {
    return NetworkSnapshotService.probe(`${AppConstants.BASE_URL}/session/csrf.json`, 'application/json', false);
  }

  private static async probe(url: string, accept: string, expectDnsAnswer: boolean): Promise<string> {
    const request: http.HttpRequest = http.createHttp();
    const start: number = Date.now();
    try {
      const response: http.HttpResponse = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'Accept': accept },
        connectTimeout: PROBE_TIMEOUT_MS,
        readTimeout: PROBE_TIMEOUT_MS,
        expectDataType: http.HttpDataType.STRING
      });
      const elapsed: number = Date.now() - start;
      const body: string = typeof response.result === 'string' ? response.result as string : '';
      const detail: string = expectDnsAnswer
        ? (body.indexOf('"Answer"') >= 0 ? ' 有解析结果' : ' 无解析结果')
        : ` bodyLength=${body.length}`;
      return `status=${response.responseCode} 耗时=${elapsed}ms${detail}`;
    } catch (error) {
      const message: string = JSON.stringify(error);
      return `异常 耗时=${Date.now() - start}ms ${message.length > 140 ? message.substring(0, 140) : message}`;
    } finally {
      request.destroy();
    }
  }
}
/**
 * 把凭据账本翻成一段人话。单独立一个函数（而不是就地拼字符串）是为了让「快照」与
 * 「登录状态页」用同一套措辞 —— 排查时两边说法不一致会让人怀疑自己看错了。
 */
class AuthTokenStoreSummary {
  static describe(snapshot: AuthTokenSnapshot): string {
    const lines: string[] = [];
    lines.push(`认证令牌 jar=${snapshot.jarFingerprint} 备份=${snapshot.backupFingerprint}` +
      `${snapshot.backupPresent ? '' : '(无备份)'} cookie仓长度=${snapshot.headerLength}`);
    // 「jar 与备份不是同一枚」本身不是错误 —— 服务端每 10 分钟轮换，备份天然落后。
    // 它只在同时「被判死」时才危险，所以判死那两行才是重点。
    if (snapshot.jarMarkedDead || snapshot.backupMarkedDead) {
      lines.push('⚠ 本机仍持有**已被服务端拒绝过**的同一枚令牌（已停止使用它，不会再写回）');
    }
    if (snapshot.lastRejectedAt > 0) {
      lines.push(`最近一次被服务端拒签：${new Date(snapshot.lastRejectedAt).toLocaleString()} ` +
        `令牌=${snapshot.lastRejectedFingerprint}`);
      lines.push('（若时间与「在另一台设备登录」接近，就是那一次登录把本机这枚顶掉了）');
    } else {
      lines.push('本机从未被服务端拒签过认证令牌');
    }
    return lines.join('\n');
  }
}
